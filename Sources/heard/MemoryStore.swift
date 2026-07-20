import Darwin
import Foundation

struct MemoryEvent: Codable {
    let v: Int
    let type: String
    let ts: Date
    var start: Date?
    var end: Date?
    var session: String?
    var source: String?
    var speaker: String?
    var text: String?
    var confidence: Float?
    var detail: String?
}

actor MemoryStore {
    private let handle: FileHandle

    init() throws {
        try HeardPaths.prepare()
        handle = try FileHandle(forWritingTo: HeardPaths.memory)
        try handle.seekToEnd()
    }

    deinit { try? handle.close() }

    func append(_ event: MemoryEvent) throws {
        try write(event)
    }

    func append(
        _ event: MemoryEvent,
        ifCurrent generation: Int,
        generationGate: SystemAudioGeneration
    ) throws -> Bool {
        try generationGate.performIfCurrent(generation) {
            try write(event)
            return true
        } ?? false
    }

    private func write(_ event: MemoryEvent) throws {
        var data = try JSONEncoder.heard.encode(event)
        data.append(0x0A)
        try handle.write(contentsOf: data)
        try handle.synchronize()
    }
}

enum MemoryMaintenance {
    struct TimestampProbe: Decodable { let ts: Date }

    static func forget(before cutoff: Date) throws -> (removed: Int, kept: Int) {
        try requireStopped()
        try HeardPaths.prepare()
        let result = rewrite(try Data(contentsOf: HeardPaths.memory), before: cutoff)
        try replaceMemory(with: result.data)
        return (result.removed, result.kept)
    }

    static func forgetAll() throws -> (removed: Int, kept: Int) {
        try requireStopped()
        try HeardPaths.prepare()
        let result = rewriteAll(try Data(contentsOf: HeardPaths.memory))
        try replaceMemory(with: result.data)
        return (result.removed, result.kept)
    }

    static func rewrite(_ data: Data, before cutoff: Date) -> (data: Data, removed: Int, kept: Int) {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        var kept: [Data] = []
        var removed = 0
        for line in lines {
            guard let probe = try? JSONDecoder.heard.decode(TimestampProbe.self, from: Data(line)) else {
                // Preserve malformed or future-version records. Explicit deletion must never
                // silently destroy data it cannot understand.
                kept.append(Data(line))
                continue
            }
            if probe.ts < cutoff { removed += 1 } else { kept.append(Data(line)) }
        }
        var output = Data()
        for line in kept { output.append(line); output.append(0x0A) }
        return (output, removed, kept.count)
    }

    static func rewriteAll(_ data: Data) -> (data: Data, removed: Int, kept: Int) {
        let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
        return (Data(), lines.count, 0)
    }

    private static func requireStopped() throws {
        if let state = RuntimeState.load(), state.isAlive {
            throw HeardError("Stop heard before deleting history, so capture and deletion cannot race.")
        }
    }

    private static func replaceMemory(with data: Data) throws {
        let temporary = HeardPaths.root.appendingPathComponent("memory.jsonl.rewrite-\(UUID().uuidString)")
        try data.write(to: temporary, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        _ = try FileManager.default.replaceItemAt(HeardPaths.memory, withItemAt: temporary)
    }
}

struct HeardError: Error, LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}
