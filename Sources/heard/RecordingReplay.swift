import Foundation

enum RecordingReplay {
    static func run(_ arguments: [String]) async throws {
        var path: String?
        var start = 0.0
        var duration = 30.0
        var source = "system"
        var index = 0
        while index < arguments.count {
            guard index + 1 < arguments.count else { throw HeardError("Missing replay option value") }
            let value = arguments[index + 1]
            switch arguments[index] {
            case "--file": path = value
            case "--start":
                guard let parsed = Double(value), parsed >= 0, parsed.isFinite else { throw HeardError("Invalid replay start") }
                start = parsed
            case "--duration":
                guard let parsed = Double(value), parsed > 0, parsed.isFinite else { throw HeardError("Invalid replay duration") }
                duration = parsed
            case "--source":
                guard value == "microphone" || value == "system" else { throw HeardError("Invalid replay source") }
                source = value
            default: throw HeardError("Unknown replay option \(arguments[index])")
            }
            index += 2
        }
        guard let path else { throw HeardError("Usage: heard replay --file PATH [--start SECONDS] [--duration SECONDS] [--source microphone|system]") }
        guard FileManager.default.fileExists(atPath: path) else { throw HeardError("Replay file not found") }
        guard let ffmpeg = ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg"].first(where: FileManager.default.isExecutableFile(atPath:)) else {
            throw HeardError("ffmpeg is required for replay")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = ["-nostdin", "-v", "error", "-ss", String(start), "-i", path,
                             "-t", String(duration), "-ac", "1", "-ar", "16000",
                             "-f", "s16le", "-acodec", "pcm_s16le", "pipe:1"]
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        try process.run()
        defer { if process.isRunning { process.terminate() } }

        let store = try MemoryStore()
        let session = UUID().uuidString.lowercased()
        try await store.append(MemoryEvent(v: 2, type: "session_start", ts: Date(), session: session,
                                           detail: "replay; \(source); scribe_v2_realtime"))
        let scribe = ScribeRealtime(source: source, sessionID: session, store: store)
        try await scribe.start()
        let wallStart = Date()
        try await store.append(MemoryEvent(v: 2, type: "replay_origin", ts: wallStart,
                                           session: session, source: source,
                                           detail: "file offset \(start) seconds"))
        var sentSamples: Int64 = 0
        var leftover = Data()
        while let data = try output.fileHandleForReading.read(upToCount: 6_400), !data.isEmpty {
            leftover.append(data)
            let completeBytes = leftover.count - leftover.count % 2
            guard completeBytes > 0 else { continue }
            let pcm = Data(leftover.prefix(completeBytes))
            leftover.removeFirst(completeBytes)
            sentSamples += Int64(pcm.count / 2)
            let elapsed = Double(sentSamples) / 16_000
            try await scribe.sendPCM(pcm, capturedAtEnd: wallStart.addingTimeInterval(elapsed))
            let ahead = wallStart.addingTimeInterval(elapsed).timeIntervalSinceNow
            if ahead > 0 { try await Task.sleep(for: .seconds(ahead)) }
        }
        process.waitUntilExit()
        await scribe.stop()
        if process.terminationStatus != 0 {
            let detail = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            throw HeardError("ffmpeg replay failed: \(detail.prefix(300))")
        }
        try await store.append(MemoryEvent(v: 2, type: "session_stop", ts: Date(), session: session))
        print("replay session: \(session)")
        print("audio seconds: \(String(format: "%.2f", Double(sentSamples) / 16_000))")
        print("events: \(HeardPaths.memory.path)")
    }
}
