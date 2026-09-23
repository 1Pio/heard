import Foundation

enum ElevenLabsCredential {
    static let environmentName = "ELEVENLABS_API_KEY"

    static func load() throws -> String {
        if let value = preferredEnvironmentValue(in: ProcessInfo.processInfo.environment) { return value }
        guard let selector = try HeardConfiguration.load().elevenLabsKeychain else {
            throw HeardError("ElevenLabs credential unavailable. Set \(environmentName) or configure elevenLabsKeychain.service and elevenLabsKeychain.account in \(HeardPaths.config.path).")
        }
        // The signed system `security` executable has a stable Keychain identity.
        // Reading directly from an unsigned development build can block on a new
        // access prompt after each rebuild, including when Stream Deck launches it.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        process.arguments = ["find-generic-password", "-s", selector.service,
                             "-a", selector.account, "-w"]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = Date().addingTimeInterval(8)
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .newlines),
              !value.isEmpty else {
            throw HeardError("ElevenLabs credential unavailable from the configured Keychain item. Check the local service/account selector and Keychain access.")
        }
        return value
    }

    static func preferredEnvironmentValue(in environment: [String: String]) -> String? {
        guard let value = environment[environmentName]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }
}

/// One WebSocket per capture track. Scribe's partials are deliberately not
/// persisted; only the delayed committed result with word timing is canonical.
actor ScribeRealtime {
    private let source: String
    private let sessionID: String
    private let store: MemoryStore
    private let onState: @Sendable (String?) -> Void
    private var urlSession: URLSession?
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var origin: Date?
    private var sentSamples: Int64 = 0
    private var lastProviderEnd = 0.0
    private var pendingCommits: [String] = []
    private var failed = false

    init(source: String, sessionID: String, store: MemoryStore,
         onState: @escaping @Sendable (String?) -> Void = { _ in }) {
        self.source = source
        self.sessionID = sessionID
        self.store = store
        self.onState = onState
    }

    func start() async throws {
        let key = try ElevenLabsCredential.load()
        var components = URLComponents(string: "wss://api.elevenlabs.io/v1/speech-to-text/realtime")!
        components.queryItems = [
            URLQueryItem(name: "model_id", value: "scribe_v2_realtime"),
            URLQueryItem(name: "audio_format", value: "pcm_16000"),
            URLQueryItem(name: "commit_strategy", value: "vad"),
            URLQueryItem(name: "vad_silence_threshold_secs", value: "0.8"),
            URLQueryItem(name: "include_timestamps", value: "true"),
            URLQueryItem(name: "include_language_detection", value: "true")
        ]
        var request = URLRequest(url: components.url!)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        let connection = URLSession(configuration: .ephemeral)
        let task = connection.webSocketTask(with: request)
        urlSession = connection
        socket = task
        task.resume()
        do {
            let first = try await task.receive()
            let message = try Self.decode(first)
            guard message["message_type"] as? String == "session_started" else {
                throw HeardError("ElevenLabs did not start the \(source) transcription session (\(message["message_type"] as? String ?? "unknown response")).")
            }
            onState(nil)
            receiveTask = Task { await receiveLoop() }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            connection.invalidateAndCancel()
            socket = nil
            urlSession = nil
            throw error
        }
    }

    func send(_ samples: [Float], capturedAtEnd: Date) async throws {
        try await sendPCM(PCM16.encode(samples), capturedAtEnd: capturedAtEnd)
    }

    func sendPCM(_ pcm: Data, capturedAtEnd: Date) async throws {
        guard !pcm.isEmpty else { return }
        guard !failed, let socket else { throw HeardError("ElevenLabs \(source) stream is disconnected") }
        let sampleCount = pcm.count / 2
        if origin == nil {
            origin = capturedAtEnd.addingTimeInterval(-Double(sampleCount) / 16_000)
        }
        sentSamples += Int64(sampleCount)
        let object: [String: Any] = [
            "message_type": "input_audio_chunk",
            "audio_base_64": pcm.base64EncodedString(),
            "sample_rate": 16_000
        ]
        let payload = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: payload, as: UTF8.self)))
    }

    func stop() async {
        if let socket, sentSamples > 0, !failed {
            // A final commit is needed when the user stops mid-sentence.
            let silence = Data(repeating: 0, count: 3_200).base64EncodedString()
            let object: [String: Any] = [
                "message_type": "input_audio_chunk", "audio_base_64": silence,
                "sample_rate": 16_000, "commit": true
            ]
            if let payload = try? JSONSerialization.data(withJSONObject: object) {
                try? await socket.send(.string(String(decoding: payload, as: UTF8.self)))
                try? await Task.sleep(for: .seconds(4))
            }
        }
        receiveTask?.cancel()
        socket?.cancel(with: .normalClosure, reason: nil)
        urlSession?.invalidateAndCancel()
        socket = nil
        urlSession = nil
        receiveTask = nil
    }

    private func receiveLoop() async {
        guard let socket else { return }
        while !Task.isCancelled {
            do {
                let message = try Self.decode(try await socket.receive())
                try await handle(message)
            } catch {
                if !Task.isCancelled {
                    failed = true
                    onState("ElevenLabs \(source) stream disconnected")
                    try? await store.append(MemoryEvent(
                        v: 2, type: "error", ts: Date(), session: sessionID,
                        source: source, detail: "ElevenLabs stream disconnected: \(error.localizedDescription)"
                    ))
                }
                break
            }
        }
    }

    private func handle(_ message: [String: Any]) async throws {
        let kind = message["message_type"] as? String ?? "unknown"
        switch kind {
        case "partial_transcript": break
        case "committed_transcript":
            pendingCommits.append(message["text"] as? String ?? "")
        case "committed_transcript_with_timestamps":
            let fallback = pendingCommits.isEmpty ? "" : pendingCommits.removeFirst()
            let text = (message["text"] as? String ?? fallback).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let origin else { return }
            let words = message["words"] as? [[String: Any]] ?? []
            let timed = words.compactMap { word -> (String, Double, Double)? in
                guard let start = word["start"] as? Double, let end = word["end"] as? Double,
                      start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
                return (word["text"] as? String ?? word["word"] as? String ?? "", start, end)
            }
            let rawStart = timed.map(\.1).min() ?? lastProviderEnd
            let rawEnd = timed.map(\.2).max() ?? Double(sentSamples) / 16_000
            let start = max(rawStart, lastProviderEnd)
            let shift = start - rawStart
            let end = max(rawEnd + shift, start + 0.001)
            lastProviderEnd = end
            let memoryWords = timed.compactMap { word -> MemoryWord? in
                guard !word.0.isEmpty else { return nil }
                return MemoryWord(text: word.0,
                                  start: origin.addingTimeInterval(word.1 + shift),
                                  end: origin.addingTimeInterval(word.2 + shift))
            }
            let event = MemoryEvent(
                v: 2, type: "utterance", ts: origin.addingTimeInterval(end),
                start: origin.addingTimeInterval(start), end: origin.addingTimeInterval(end),
                session: sessionID, source: source,
                speaker: source == "microphone" ? "you" : "remote",
                text: text, confidence: nil, detail: nil,
                model: "scribe_v2_realtime",
                timing: timed.isEmpty ? "estimated" : (shift > 0 ? "shifted" : "word"),
                language: message["language_code"] as? String,
                words: memoryWords.isEmpty ? nil : memoryWords,
                receivedAt: Date()
            )
            try await store.append(event)
        case "warning":
            try await store.append(MemoryEvent(v: 2, type: "warning", ts: Date(), session: sessionID,
                                               source: source, detail: message["warning"] as? String ?? "ElevenLabs warning"))
        default:
            let terminalEvents: Set<String> = [
                "error", "rate_limited", "quota_exceeded", "queue_overflow",
                "resource_exhausted", "session_time_limit_exceeded", "chunk_size_exceeded",
                "insufficient_audio_activity", "commit_throttled", "unaccepted_terms", "invalid_request"
            ]
            if terminalEvents.contains(kind) || kind.hasSuffix("_error") {
                failed = true
                onState("ElevenLabs \(source): \(kind)")
                throw HeardError("ElevenLabs \(source): \(kind)")
            }
        }
    }

    private static func decode(_ message: URLSessionWebSocketTask.Message) throws -> [String: Any] {
        let data: Data
        switch message {
        case .string(let value): data = Data(value.utf8)
        case .data(let value): data = value
        @unknown default: throw HeardError("Unexpected ElevenLabs WebSocket message")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HeardError("Invalid ElevenLabs WebSocket response")
        }
        return object
    }
}

enum PCM16 {
    static func encode(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for sample in samples {
            let value = Int16((max(-1, min(1, sample)) * 32767).rounded())
            data.append(UInt8(truncatingIfNeeded: value))
            data.append(UInt8(truncatingIfNeeded: value >> 8))
        }
        return data
    }
}
