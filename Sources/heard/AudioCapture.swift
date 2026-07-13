@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
@preconcurrency import ScreenCaptureKit

/// Converts arbitrary PCM buffers to the one format used by the inference pipeline:
/// 16 kHz, mono, Float32, non-interleaved.
final class Mono16kConverter: @unchecked Sendable {
    private final class Supply: @unchecked Sendable { var used = false }
    private let lock = NSLock()
    private var converter: AVAudioConverter?
    private var inputFormat: AVAudioFormat?
    private let outputFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 16_000,
        channels: 1,
        interleaved: false
    )!

    func convert(_ buffer: AVAudioPCMBuffer) -> [Float] {
        lock.lock()
        defer { lock.unlock() }

        if inputFormat != buffer.format {
            inputFormat = buffer.format
            converter = AVAudioConverter(from: buffer.format, to: outputFormat)
        }
        guard let converter else { return [] }
        let ratio = outputFormat.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(buffer.frameLength) * ratio)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else { return [] }

        let supply = Supply()
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            if supply.used {
                outStatus.pointee = .noDataNow
                return nil
            }
            supply.used = true
            outStatus.pointee = .haveData
            return buffer
        }
        guard status != .error, output.frameLength > 0, let channel = output.floatChannelData?[0] else {
            return []
        }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

final class MicrophoneCapture: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = Mono16kConverter()
    private let onSamples: @Sendable ([Float]) -> Void

    init(onSamples: @escaping @Sendable ([Float]) -> Void) { self.onSamples = onSamples }

    func start() async throws {
        let allowed: Bool
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: allowed = true
        case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .audio)
        default: allowed = false
        }
        guard allowed else {
            throw HeardError("Microphone access was denied. Allow it for your terminal in System Settings > Privacy & Security > Microphone.")
        }

        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw HeardError("No usable default microphone was found.")
        }
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            let samples = self.converter.convert(buffer)
            if !samples.isEmpty { self.onSamples(samples) }
        }
        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

final class SystemAudioCapture: NSObject, @unchecked Sendable, SCStreamOutput, SCStreamDelegate {
    private let converter = Mono16kConverter()
    private let onSamples: @Sendable ([Float]) -> Void
    private let queue = DispatchQueue(label: "heard.system-audio", qos: .userInitiated)
    private var stream: SCStream?

    init(onSamples: @escaping @Sendable ([Float]) -> Void) { self.onSamples = onSamples }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw HeardError("System-audio access was denied. Allow heard (or your terminal) in System Settings > Privacy & Security > Screen & System Audio Recording, then run `heard start` again.")
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else { throw HeardError("No display is available for system-audio capture.") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.capturesAudio = true
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .audio)
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let formatDescription = sampleBuffer.formatDescription else { return }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)
        do {
            try sampleBuffer.withAudioBufferList { audioBufferList, _ in
                guard let buffer = AVAudioPCMBuffer(
                    pcmFormat: format,
                    bufferListNoCopy: audioBufferList.unsafePointer,
                    deallocator: nil
                ) else { return }
                buffer.frameLength = AVAudioFrameCount(sampleBuffer.numSamples)
                let samples = converter.convert(buffer)
                if !samples.isEmpty { onSamples(samples) }
            }
        } catch {
            // A single malformed host buffer must not terminate a long-running session.
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        fputs("[heard] system audio stopped: \(error.localizedDescription)\n", stderr)
    }
}
