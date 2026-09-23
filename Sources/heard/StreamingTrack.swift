import Foundation

struct AudioBatch: Sendable {
    let samples: [Float]
    let capturedAtEnd: Date
    let synthetic: Bool
    let filterGeneration: Int?

    init(samples: [Float], capturedAtEnd: Date, synthetic: Bool = false,
         filterGeneration: Int? = nil) {
        self.samples = samples
        self.capturedAtEnd = capturedAtEnd
        self.synthetic = synthetic
        self.filterGeneration = filterGeneration
    }
}

/// Serializes one source into 200 ms PCM chunks. Source tracks remain separate,
/// so microphone and remote speech can genuinely overlap in the transcript.
actor StreamingTrack {
    private let source: String
    private let session: String
    private let store: MemoryStore
    private let archive: PCMArchive
    private let onState: @Sendable (String?) -> Void
    private var scribe: ScribeRealtime?
    private var pending = Data()
    private var timelineOrigin: Date?
    private var emittedSamples: Int64 = 0
    private var reconnectFailures = 0
    private var nextReconnectAt = Date.distantPast
    private var reportedRecording = false

    init(source: String, session: String, store: MemoryStore,
         onState: @escaping @Sendable (String?) -> Void) throws {
        self.source = source
        self.session = session
        self.store = store
        self.archive = try PCMArchive(session: session, source: source)
        self.onState = onState
    }

    func start() async throws {
        let connection = ScribeRealtime(source: source, sessionID: session, store: store, onState: onState)
        try await connection.start()
        scribe = connection
    }

    func accept(_ batch: AudioBatch) async {
        guard !batch.samples.isEmpty else { return }
        var pcm = PCM16.encode(batch.samples)
        let batchStart = batch.capturedAtEnd.addingTimeInterval(-Double(batch.samples.count) / 16_000)
        if timelineOrigin == nil { timelineOrigin = batchStart }
        guard var origin = timelineOrigin else { return }
        let expected = origin.addingTimeInterval(Double(emittedSamples + Int64(pending.count / 2)) / 16_000)
        let difference = batchStart.timeIntervalSince(expected)
        if difference > 2 {
            try? await store.append(MemoryEvent(v: 2, type: "capture_gap", ts: batchStart,
                                                start: expected, end: batchStart, session: session,
                                                source: source, detail: "source callbacks interrupted; Scribe timeline restarted"))
            await flush()
            await scribe?.stop()
            scribe = nil
            timelineOrigin = batchStart
            origin = batchStart
            emittedSamples = 0
            pending.removeAll(keepingCapacity: true)
        } else if difference > 0.15 {
            let gapSamples = Int((difference * 16_000).rounded())
            pending.append(Data(repeating: 0, count: gapSamples * 2))
        } else if difference < -0.15 {
            let overlapSamples = Int((-difference * 16_000).rounded())
            guard overlapSamples < batch.samples.count else { return }
            pcm.removeFirst(overlapSamples * 2)
        }
        pending.append(pcm)
        if !reportedRecording, !batch.synthetic {
            reportedRecording = true
            let stats = await archive.statistics()
            try? await store.append(MemoryEvent(v: 2, type: "recording_start", ts: batchStart,
                                                session: session, source: source, detail: stats.directory))
        }
        while pending.count >= 6_400 {
            let chunk = Data(pending.prefix(6_400))
            pending.removeFirst(6_400)
            emittedSamples += 3_200
            let end = origin.addingTimeInterval(Double(emittedSamples) / 16_000)
            await emit(chunk, end: end)
        }
    }

    func finish() async {
        await flush()
        await scribe?.stop()
        scribe = nil
        try? await archive.close()
    }

    private func flush() async {
        guard !pending.isEmpty, let origin = timelineOrigin else { return }
        let chunk = pending
        pending.removeAll(keepingCapacity: true)
        emittedSamples += Int64(chunk.count / 2)
        let end = origin.addingTimeInterval(Double(emittedSamples) / 16_000)
        await emit(chunk, end: end)
    }

    private func emit(_ chunk: Data, end: Date) async {
        do { try await archive.append(chunk) }
        catch {
            onState("recording failed for \(source)")
            try? await store.append(MemoryEvent(v: 2, type: "error", ts: Date(), session: session,
                                                source: source, detail: "recording failed: \(error.localizedDescription)"))
        }
        if scribe == nil, Date() >= nextReconnectAt {
            let connection = ScribeRealtime(source: source, sessionID: session, store: store, onState: onState)
            do {
                try await connection.start()
                scribe = connection
                reconnectFailures = 0
                onState(nil)
                try? await store.append(MemoryEvent(v: 2, type: "transcription_resumed", ts: Date(),
                                                    session: session, source: source))
            } catch {
                reconnectFailures = min(reconnectFailures + 1, 5)
                nextReconnectAt = Date().addingTimeInterval(min(60, Double(5 * (1 << (reconnectFailures - 1)))))
                onState("ElevenLabs \(source) reconnect failed")
                try? await store.append(MemoryEvent(v: 2, type: "transcription_retry", ts: Date(),
                                                    session: session, source: source,
                                                    detail: "connection failed; local recording continues"))
            }
        }
        guard let scribe else { return }
        do { try await scribe.sendPCM(chunk, capturedAtEnd: end) }
        catch {
            onState("ElevenLabs \(source) stream disconnected")
            await scribe.stop()
            self.scribe = nil
            nextReconnectAt = Date().addingTimeInterval(2)
            try? await store.append(MemoryEvent(v: 2, type: "transcription_gap", ts: end,
                                                session: session, source: source,
                                                detail: "ElevenLabs disconnected; capture continues locally"))
        }
    }
}
