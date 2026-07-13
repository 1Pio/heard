import FluidAudio
import Foundation

struct SpeechChunk: Sendable {
    let source: String
    let samples: [Float]
    let start: Date
    let end: Date
    let overlapsPrevious: Bool
}

actor SpeechChunker {
    static let forcedCommitSeconds = 5.0
    static let overlapSeconds = 0.75
    private let source: String
    private let vad: VadManager
    private var vadState: VadStreamState
    private let segmentation = VadSegmentationConfig(
        minSpeechDuration: 0.2,
        minSilenceDuration: 0.65,
        maxSpeechDuration: forcedCommitSeconds,
        speechPadding: 0.1
    )
    private var pending: [Float] = []
    private var preRoll: [Float] = []
    private var speech: [Float] = []
    private var speechStart: Date?
    private var continuedFromCut = false
    private let emit: @Sendable (SpeechChunk) async -> Void

    init(source: String, vad: VadManager, emit: @escaping @Sendable (SpeechChunk) async -> Void) async {
        self.source = source
        self.vad = vad
        self.vadState = await vad.makeStreamState()
        self.emit = emit
    }

    func accept(_ samples: [Float], capturedAt: Date = Date()) async {
        pending.append(contentsOf: samples)
        while pending.count >= VadManager.chunkSize {
            let chunk = Array(pending.prefix(VadManager.chunkSize))
            pending.removeFirst(VadManager.chunkSize)
            await process(chunk, capturedAt: capturedAt)
        }
    }

    private func process(_ chunk: [Float], capturedAt: Date) async {
        guard let result = try? await vad.processStreamingChunk(
            chunk,
            state: vadState,
            config: segmentation
        ) else { return }
        vadState = result.state

        let chunkDuration = Double(chunk.count) / 16_000
        if !speech.isEmpty || result.state.triggered {
            if speech.isEmpty {
                speech = preRoll
                speechStart = capturedAt.addingTimeInterval(-chunkDuration - Double(preRoll.count) / 16_000)
            }
            speech.append(contentsOf: chunk)
        }

        if let event = result.event, event.kind == .speechEnd {
            await flush(end: capturedAt, keepOverlap: false)
        } else if speech.count >= Int(Self.forcedCommitSeconds * 16_000) {
            await flush(end: capturedAt, keepOverlap: true)
        }

        preRoll.append(contentsOf: chunk)
        if preRoll.count > 8_000 { preRoll.removeFirst(preRoll.count - 8_000) }
    }

    func flush(end: Date = Date()) async { await flush(end: end, keepOverlap: false) }

    private func flush(end: Date, keepOverlap: Bool) async {
        let minimumSamples = Int(0.35 * 16_000)
        guard speech.count >= minimumSamples, let start = speechStart else {
            speech.removeAll(keepingCapacity: true)
            speechStart = nil
            continuedFromCut = false
            return
        }
        let emitted = SpeechChunk(
            source: source,
            samples: speech,
            start: start,
            end: end,
            overlapsPrevious: continuedFromCut
        )
        await emit(emitted)

        if keepOverlap {
            let overlapCount = min(Int(Self.overlapSeconds * 16_000), speech.count)
            speech = Array(speech.suffix(overlapCount))
            speechStart = end.addingTimeInterval(-Double(overlapCount) / 16_000)
            continuedFromCut = true
        } else {
            speech.removeAll(keepingCapacity: true)
            speechStart = nil
            continuedFromCut = false
        }
    }
}

actor TranscriptionPipeline {
    private let store: MemoryStore
    private let session: String
    private let asr: AsrManager
    private let diarizer: DiarizerManager?
    private var speakers = SpeakerManager(
        speakerThreshold: 0.58,
        embeddingThreshold: 0.42,
        minSpeechDuration: 1.0,
        minEmbeddingUpdateDuration: 2.0
    )
    private var lastWords: [String: [String]] = [:]

    init(store: MemoryStore, session: String, enableDiarization: Bool = true) async throws {
        self.store = store
        self.session = session

        fputs("[heard] loading local transcription model (first run downloads about 450 MB)...\n", stderr)
        let models = try await AsrModels.downloadAndLoad(version: .v3)
        let manager = AsrManager(config: .default)
        try await manager.loadModels(models)
        self.asr = manager

        if enableDiarization {
            do {
                fputs("[heard] loading local speaker model...\n", stderr)
                let manager = DiarizerManager(config: .default)
                let models = try await DiarizerModels.downloadIfNeeded()
                manager.initialize(models: models)
                self.diarizer = manager
            } catch {
                self.diarizer = nil
                fputs("[heard] speaker model unavailable; remote speech will use a stable 'remote' label: \(error.localizedDescription)\n", stderr)
            }
        } else {
            self.diarizer = nil
        }
        fputs("[heard] models ready\n", stderr)
    }

    func transcribe(_ chunk: SpeechChunk) async {
        do {
            var decoderState = TdtDecoderState.make(decoderLayers: await asr.decoderLayerCount)
            let result = try await asr.transcribe(chunk.samples, decoderState: &decoderState)
            var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }
            if chunk.overlapsPrevious { text = removeRepeatedPrefix(from: text, source: chunk.source) }
            guard !text.isEmpty else { return }

            let speaker = identifySpeaker(for: chunk)
            let sentences = splitSentences(text)
            let weights = sentences.map { max(1, $0.split(whereSeparator: \.isWhitespace).count) }
            let totalWeight = max(1, weights.reduce(0, +))
            let duration = max(0.01, chunk.end.timeIntervalSince(chunk.start))
            var elapsed = 0.0
            for (index, sentence) in sentences.enumerated() {
                let sentenceDuration = duration * Double(weights[index]) / Double(totalWeight)
                let start = chunk.start.addingTimeInterval(elapsed)
                elapsed += sentenceDuration
                let end = index == sentences.count - 1 ? chunk.end : chunk.start.addingTimeInterval(elapsed)
                try await store.append(MemoryEvent(
                    v: 1,
                    type: "utterance",
                    ts: end,
                    start: start,
                    end: end,
                    session: session,
                    source: chunk.source,
                    speaker: speaker,
                    text: sentence,
                    confidence: result.confidence,
                    detail: nil
                ))
            }
            lastWords[chunk.source] = normalizedWords(text).suffix(24).map { $0 }
        } catch {
            try? await store.append(MemoryEvent(
                v: 1, type: "error", ts: Date(), session: session,
                detail: "transcription failed for \(chunk.source): \(error.localizedDescription)"
            ))
        }
    }

    private func identifySpeaker(for chunk: SpeechChunk) -> String {
        if chunk.source == "microphone" { return "you" }
        guard chunk.samples.count >= 16_000, let diarizer,
              let embedding = try? diarizer.extractSpeakerEmbedding(from: chunk.samples),
              let speaker = speakers.assignSpeaker(
                embedding,
                speechDuration: Float(chunk.samples.count) / 16_000,
                newName: nil
              ) else { return "remote" }
        return "remote-\(speaker.id)"
    }

    private func splitSentences(_ text: String) -> [String] {
        let pattern = #"(?<=[.!?])\s+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [text] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let parts = regex.split(text, range: range)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return parts.isEmpty ? [text] : parts
    }

    private func normalizedWords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    private func removeRepeatedPrefix(from text: String, source: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace).map(String.init)
        let normalized = normalizedWords(text)
        guard let previous = lastWords[source], !previous.isEmpty else { return text }
        let limit = min(16, previous.count, normalized.count)
        for count in stride(from: limit, through: 3, by: -1) {
            if Array(previous.suffix(count)) == Array(normalized.prefix(count)), words.count >= count {
                return words.dropFirst(count).joined(separator: " ")
            }
        }
        return text
    }
}

private extension NSRegularExpression {
    func split(_ string: String, range: NSRange) -> [String] {
        var result: [String] = []
        var cursor = range.location
        for match in matches(in: string, range: range) {
            let part = NSRange(location: cursor, length: match.range.location - cursor)
            if let swiftRange = Range(part, in: string) { result.append(String(string[swiftRange])) }
            cursor = match.range.location + match.range.length
        }
        let tail = NSRange(location: cursor, length: NSMaxRange(range) - cursor)
        if let swiftRange = Range(tail, in: string) { result.append(String(string[swiftRange])) }
        return result
    }
}
