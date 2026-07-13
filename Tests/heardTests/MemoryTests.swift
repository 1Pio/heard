import Foundation
import FluidAudio
import Testing
@testable import heard

@Test func isoTimestampsRoundTripFractionalSeconds() throws {
    let date = Date(timeIntervalSince1970: 1_752_323_456.789)
    let encoded = ISOTime.string(date)
    let decoded = try #require(ISOTime.parse(encoded))
    #expect(abs(decoded.timeIntervalSince(date)) < 0.001)
}

@Test func localModelTranscribesFixtureWhenRequested() async throws {
    guard let path = ProcessInfo.processInfo.environment["HEARD_INTEGRATION_AUDIO"] else { return }
    let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
    let models = try await AsrModels.downloadAndLoad(version: .v3)
    let manager = AsrManager(config: .default)
    try await manager.loadModels(models)
    var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
    let result = try await manager.transcribe(samples, decoderState: &state)
    #expect(result.text.lowercased().contains("prototype"))
    #expect(!result.text.isEmpty)
}

private actor ChunkCollector {
    var chunks: [SpeechChunk] = []
    func append(_ chunk: SpeechChunk) { chunks.append(chunk) }
}

@Test func localVadFindsFixtureSpeechWhenRequested() async throws {
    guard let path = ProcessInfo.processInfo.environment["HEARD_INTEGRATION_AUDIO"] else { return }
    let samples = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
    let vad = try await VadManager()
    let collector = ChunkCollector()
    let chunker = await SpeechChunker(source: "fixture", vad: vad) { chunk in
        await collector.append(chunk)
    }
    var cursor = 0
    while cursor < samples.count {
        let end = min(samples.count, cursor + 2048)
        await chunker.accept(Array(samples[cursor..<end]))
        cursor = end
    }
    await chunker.accept([Float](repeating: 0, count: 20_000))
    await chunker.flush()
    let chunks = await collector.chunks
    #expect(!chunks.isEmpty)
    #expect(chunks.reduce(0) { $0 + $1.samples.count } > 16_000)
}

@Test func continuousSpeechIsForcedIntoLiveFiveSecondCommitsWhenRequested() async throws {
    guard let path = ProcessInfo.processInfo.environment["HEARD_INTEGRATION_AUDIO"] else { return }
    let fixture = try AudioConverter().resampleAudioFile(URL(fileURLWithPath: path))
    let continuous = Array(repeating: fixture, count: 4).flatMap { $0 }
    let vad = try await VadManager()
    let collector = ChunkCollector()
    let chunker = await SpeechChunker(source: "fixture", vad: vad) { chunk in
        await collector.append(chunk)
    }
    var cursor = 0
    while cursor < continuous.count {
        let end = min(continuous.count, cursor + 2048)
        await chunker.accept(Array(continuous[cursor..<end]))
        cursor = end
    }
    await chunker.flush()
    let chunks = await collector.chunks
    #expect(chunks.count >= 2)
    #expect(chunks.contains { $0.overlapsPrevious })
    #expect(chunks.dropLast().allSatisfy { $0.samples.count <= 6 * 16_000 })
}

@Test func memoryEventsAreSingleLineJSON() throws {
    let event = MemoryEvent(
        v: 1,
        type: "utterance",
        ts: Date(timeIntervalSince1970: 1_752_323_456),
        start: Date(timeIntervalSince1970: 1_752_323_455),
        end: Date(timeIntervalSince1970: 1_752_323_456),
        session: "test",
        source: "microphone",
        speaker: "you",
        text: "A line-safe sentence.",
        confidence: 0.9,
        detail: nil
    )
    let data = try JSONEncoder.heard.encode(event)
    #expect(!data.contains(0x0A))
    let decoded = try JSONDecoder.heard.decode(MemoryEvent.self, from: data)
    #expect(decoded.text == event.text)
}

@Test func statusDistinguishesWorkingMicrophoneFromDeniedSystemAudio() {
    let now = Date()
    let state = RuntimeState(
        pid: 42,
        status: "running",
        startedAt: now.addingTimeInterval(-30),
        updatedAt: now,
        captureSystemAudio: false,
        lastError: nil,
        requestedSystemAudio: true,
        systemAudioError: "permission denied"
    )
    let health = CaptureHealthSnapshot(
        pid: 42,
        writtenAt: now,
        microphoneCallbacks: 100,
        lastMicrophoneCallbackAt: now.addingTimeInterval(-0.1),
        systemAudioCallbacks: 0,
        lastSystemAudioCallbackAt: nil
    )
    let lines = StatusFormatter.lines(state: state, health: health, now: now)
    #expect(lines.contains("microphone: listening (live audio callbacks)"))
    #expect(lines.contains { $0.hasPrefix("system audio: unavailable") })
    #expect(!lines.contains { $0.hasPrefix("warning: system audio") })
}

@Test func statusDoesNotClaimPermissionFailureWhileStarting() {
    let now = Date()
    let state = RuntimeState(
        pid: 42, status: "starting", startedAt: now, updatedAt: now,
        captureSystemAudio: false, lastError: nil,
        requestedSystemAudio: true, systemAudioError: nil
    )
    let lines = StatusFormatter.lines(state: state, health: nil, now: now)
    #expect(lines.contains("microphone: initializing"))
    #expect(lines.contains("system audio: initializing"))
}
