import Darwin
import Foundation

struct FollowOptions: Equatable {
    let simple: Bool
    let since: TimeInterval?

    static func parse(_ arguments: [String]) throws -> Self {
        var simple = false
        var since: TimeInterval?
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--simple":
                guard !simple else { throw HeardError("--simple may only be specified once.") }
                simple = true
                index += 1
            case "--since":
                guard since == nil else { throw HeardError("--since may only be specified once.") }
                guard index + 1 < arguments.count else {
                    throw HeardError("--since requires a duration such as 5m.")
                }
                since = try DurationParser.parse(arguments[index + 1])
                index += 2
            default:
                throw HeardError("Unknown follow option: \(arguments[index])")
            }
        }
        return Self(simple: simple, since: since)
    }
}

enum DurationParser {
    static func parse(_ value: String) throws -> TimeInterval {
        guard let unit = value.last else { throw invalid(value) }
        let number = String(value.dropLast())
        guard let amount = Double(number), amount > 0, amount.isFinite else { throw invalid(value) }
        let multiplier: Double
        switch unit.lowercased() {
        case "s": multiplier = 1
        case "m": multiplier = 60
        case "h": multiplier = 3_600
        case "d": multiplier = 86_400
        default: throw invalid(value)
        }
        return amount * multiplier
    }

    private static func invalid(_ value: String) -> HeardError {
        HeardError("Invalid duration '\(value)'. Use a positive duration such as 30s, 5m, 2h, or 1d.")
    }
}

struct MemoryLinePresenter {
    let simple: Bool
    let historicalCutoff: Date?

    func output(for data: Data, historical: Bool) -> String? {
        if historical, let historicalCutoff {
            guard let probe = try? JSONDecoder.heard.decode(MemoryMaintenance.TimestampProbe.self, from: data),
                  probe.ts >= historicalCutoff else { return nil }
        }
        guard simple else { return String(data: data, encoding: .utf8) }
        guard let event = try? JSONDecoder.heard.decode(MemoryEvent.self, from: data),
              event.type == "utterance", let text = event.text else { return nil }
        return "[\(ISOTime.string(event.ts))] \(text)"
    }
}

enum MemoryFollower {
    static func follow(options: FollowOptions, now: Date = Date()) async throws {
        try HeardPaths.prepare()
        var handle = try FileHandle(forReadingFrom: HeardPaths.memory)
        defer { try? handle.close() }

        let snapshotEnd = try handle.seekToEnd()
        let startOffset: UInt64
        if options.since != nil {
            startOffset = 0
        } else {
            startOffset = try tailStartOffset(handle: handle, endOffset: snapshotEnd, lineCount: 10)
        }
        try handle.seek(toOffset: startOffset)

        let presenter = MemoryLinePresenter(
            simple: options.simple,
            historicalCutoff: options.since.map { now.addingTimeInterval(-$0) }
        )
        var buffer = Data()
        var remaining = snapshotEnd - startOffset
        while remaining > 0 {
            let count = min(64 * 1_024, Int(remaining))
            guard let data = try handle.read(upToCount: count), !data.isEmpty else { break }
            remaining -= UInt64(data.count)
            buffer.append(data)
            emitCompleteLines(from: &buffer, presenter: presenter, historical: true)
        }

        while !Task.isCancelled {
            if let data = try handle.read(upToCount: 64 * 1_024), !data.isEmpty {
                buffer.append(data)
                emitCompleteLines(from: &buffer, presenter: presenter, historical: false)
            } else if try wasReplacedOrTruncated(handle) {
                try handle.close()
                handle = try FileHandle(forReadingFrom: HeardPaths.memory)
                _ = try handle.seekToEnd()
                buffer.removeAll(keepingCapacity: true)
            } else {
                try await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private static func wasReplacedOrTruncated(_ handle: FileHandle) throws -> Bool {
        var descriptorInfo = stat()
        guard fstat(handle.fileDescriptor, &descriptorInfo) == 0 else {
            throw HeardError("Could not inspect the open memory log.")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: HeardPaths.memory.path)
        let pathInode = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        let pathSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let offset = try handle.offset()
        return pathInode != UInt64(descriptorInfo.st_ino) || pathSize < offset
    }

    private static func emitCompleteLines(
        from buffer: inout Data,
        presenter: MemoryLinePresenter,
        historical: Bool
    ) {
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard !line.isEmpty, let output = presenter.output(for: line, historical: historical) else { continue }
            print(output)
            fflush(stdout)
        }
    }

    private static func tailStartOffset(
        handle: FileHandle,
        endOffset: UInt64,
        lineCount: Int
    ) throws -> UInt64 {
        guard endOffset > 0, lineCount > 0 else { return endOffset }
        try handle.seek(toOffset: endOffset - 1)
        let endsWithNewline = try handle.read(upToCount: 1)?.first == 0x0A
        let targetNewlines = lineCount + (endsWithNewline ? 1 : 0)
        var found = 0
        var cursor = endOffset
        while cursor > 0 {
            let start = cursor > 8_192 ? cursor - 8_192 : 0
            try handle.seek(toOffset: start)
            let data = try handle.read(upToCount: Int(cursor - start)) ?? Data()
            for index in data.indices.reversed() where data[index] == 0x0A {
                found += 1
                if found == targetNewlines { return start + UInt64(index) + 1 }
            }
            cursor = start
        }
        return 0
    }
}
