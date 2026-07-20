@preconcurrency import AVFoundation
@preconcurrency import AppKit
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
    private let excludedBundleIdentifiers: Set<String>
    private let onFilterChange: @Sendable () async -> Void
    private let onFilterInvalidated: @Sendable (Int) -> Void
    private let onFilterState: @Sendable (String?) -> Void
    private let onSamples: @Sendable ([Float], Int) -> Void
    private let queue = DispatchQueue(label: "heard.system-audio", qos: .userInitiated)
    private let stateLock = NSLock()
    private var stream: SCStream?
    private var display: SCDisplay?
    private var samplesEnabled = false
    private var filterGeneration = 0
    private var excludedProcessIDs: Set<pid_t> = []
    private var pendingBundleIdentifier: String?
    private var pendingProcessID: pid_t?
    private var pendingExpectedRunning: Bool?
    private var applicationObservers: [NSObjectProtocol] = []
    private var filterCoordinator: ApplicationFilterCoordinator!

    init(
        excludedBundleIdentifiers: [String] = [],
        onFilterChange: @escaping @Sendable () async -> Void = {},
        onFilterInvalidated: @escaping @Sendable (Int) -> Void = { _ in },
        onFilterState: @escaping @Sendable (String?) -> Void = { _ in },
        onSamples: @escaping @Sendable ([Float], Int) -> Void
    ) {
        self.excludedBundleIdentifiers = Set(excludedBundleIdentifiers.map { $0.lowercased() })
        self.onFilterChange = onFilterChange
        self.onFilterInvalidated = onFilterInvalidated
        self.onFilterState = onFilterState
        self.onSamples = onSamples
        super.init()
        filterCoordinator = ApplicationFilterCoordinator(capture: self)
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess() else {
            throw HeardError("System-audio access was denied. Allow heard (or your terminal) in System Settings > Privacy & Security > Screen & System Audio Recording, then run `heard start` again.")
        }
        installApplicationObservers()
        let initialGeneration = currentFilterGeneration()
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let display = content.displays.first else { throw HeardError("No display is available for system-audio capture.") }
            let excludedApplications = matchingApplications(in: content)
            let unresolvedApplications = unresolvedRunningApplications(excluding: excludedApplications)
            guard unresolvedApplications.isEmpty else {
                throw HeardError(
                    "Could not safely exclude running app(s): \(unresolvedApplications.joined(separator: ", ")). System audio was not started."
                )
            }
            let filter = SCContentFilter(
                display: display,
                excludingApplications: excludedApplications,
                exceptingWindows: []
            )
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
            self.display = display
            stateLock.withLock {
                excludedProcessIDs = Set(excludedApplications.map(\.processID))
            }
            reportExcludedApplications(excludedApplications)
            onFilterState(nil)
            if currentFilterGeneration() == initialGeneration {
                enableSamples(ifCurrent: initialGeneration)
            } else {
                let pending = pendingFilterRefresh()
                Task {
                    await filterCoordinator.refresh(
                        generation: pending.generation,
                        bundleIdentifier: pending.bundleIdentifier,
                        processID: pending.processID,
                        expectedRunning: pending.expectedRunning
                    )
                }
            }
        } catch {
            removeApplicationObservers()
            throw error
        }
    }

    func stop() async {
        removeApplicationObservers()
        stateLock.withLock {
            samplesEnabled = false
            filterGeneration &+= 1
        }
        guard let stream else { return }
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .audio)
        self.stream = nil
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, sampleBuffer.numSamples > 0 else { return }
        guard let generation = stateLock.withLock({ samplesEnabled ? filterGeneration : nil }) else { return }
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
                if !samples.isEmpty { onSamples(samples, generation) }
            }
        } catch {
            // A single malformed host buffer must not terminate a long-running session.
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        stateLock.withLock { samplesEnabled = false }
        fputs("[heard] system audio stopped: \(error.localizedDescription)\n", stderr)
        onFilterState(error.localizedDescription)
    }

    fileprivate func refreshApplicationFilter(
        generation: Int,
        bundleIdentifier: String?,
        processID: pid_t?,
        expectedRunning: Bool?
    ) async throws -> Bool {
        guard !excludedBundleIdentifiers.isEmpty, let stream, let display else { return false }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let excludedApplications = matchingApplications(in: content)
        if let bundleIdentifier, let processID, let expectedRunning {
            let isRunning = excludedApplications.contains {
                $0.processID == processID
                    && $0.bundleIdentifier.caseInsensitiveCompare(bundleIdentifier) == .orderedSame
            }
            guard isRunning == expectedRunning else { return false }
        }
        let processIDs = Set(excludedApplications.map(\.processID))
        let changed = stateLock.withLock { processIDs != excludedProcessIDs }
        guard changed else {
            enableSamples(ifCurrent: generation)
            return true
        }
        await onFilterChange()
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApplications,
            exceptingWindows: []
        )
        try await stream.updateContentFilter(filter)
        stateLock.withLock { excludedProcessIDs = processIDs }
        reportExcludedApplications(excludedApplications)
        onFilterState(nil)
        enableSamples(ifCurrent: generation)
        return true
    }

    fileprivate func filterRefreshFailed() {
        let message = "app exclusion filter could not be refreshed"
        stateLock.withLock { samplesEnabled = false }
        onFilterState(message)
        fputs("[heard] \(message); system audio remains paused\n", stderr)
    }

    private func matchingApplications(in content: SCShareableContent) -> [SCRunningApplication] {
        guard !excludedBundleIdentifiers.isEmpty else { return [] }
        return content.applications.filter {
            excludedBundleIdentifiers.contains($0.bundleIdentifier.lowercased())
        }
    }

    private func unresolvedRunningApplications(
        excluding applications: [SCRunningApplication]
    ) -> [String] {
        let resolvedProcessIDs = Set(applications.map(\.processID))
        return NSWorkspace.shared.runningApplications.compactMap { application in
            guard let bundleIdentifier = application.bundleIdentifier,
                  excludedBundleIdentifiers.contains(bundleIdentifier.lowercased()),
                  !resolvedProcessIDs.contains(application.processIdentifier) else { return nil }
            return "\(application.localizedName ?? bundleIdentifier) (\(bundleIdentifier))"
        }.sorted()
    }

    private func installApplicationObservers() {
        guard !excludedBundleIdentifiers.isEmpty else {
            stateLock.withLock { samplesEnabled = true }
            return
        }
        let center = NSWorkspace.shared.notificationCenter
        applicationObservers.append(center.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            self?.applicationStateChanged(notification, expectedRunning: true)
        })
        applicationObservers.append(center.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: nil
        ) { [weak self] notification in
            self?.applicationStateChanged(notification, expectedRunning: false)
        })
    }

    private func removeApplicationObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in applicationObservers { center.removeObserver(observer) }
        applicationObservers.removeAll()
    }

    private func applicationStateChanged(_ notification: Notification, expectedRunning: Bool) {
        guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let bundleIdentifier = application.bundleIdentifier,
              excludedBundleIdentifiers.contains(bundleIdentifier.lowercased()) else { return }
        let generation = stateLock.withLock { () -> Int in
            samplesEnabled = false
            filterGeneration &+= 1
            pendingBundleIdentifier = bundleIdentifier
            pendingProcessID = application.processIdentifier
            pendingExpectedRunning = expectedRunning
            return filterGeneration
        }
        onFilterInvalidated(generation)
        Task {
            await filterCoordinator.refresh(
                generation: generation,
                bundleIdentifier: bundleIdentifier,
                processID: application.processIdentifier,
                expectedRunning: expectedRunning
            )
        }
    }

    private func currentFilterGeneration() -> Int {
        stateLock.withLock { filterGeneration }
    }

    private func enableSamples(ifCurrent generation: Int) {
        stateLock.withLock {
            if filterGeneration == generation {
                samplesEnabled = true
                pendingBundleIdentifier = nil
                pendingProcessID = nil
                pendingExpectedRunning = nil
            }
        }
    }

    private func pendingFilterRefresh() -> (
        generation: Int,
        bundleIdentifier: String?,
        processID: pid_t?,
        expectedRunning: Bool?
    ) {
        stateLock.withLock {
            (filterGeneration, pendingBundleIdentifier, pendingProcessID, pendingExpectedRunning)
        }
    }

    private func reportExcludedApplications(_ applications: [SCRunningApplication]) {
        guard !excludedBundleIdentifiers.isEmpty else { return }
        let active = Set(applications.map { $0.bundleIdentifier.lowercased() })
        let waiting = excludedBundleIdentifiers.subtracting(active).sorted()
        if !applications.isEmpty {
            let descriptions = applications
                .map { "\($0.applicationName) (\($0.bundleIdentifier))" }
                .sorted()
                .joined(separator: ", ")
            fputs("[heard] excluding system audio from: \(descriptions)\n", stderr)
        }
        if !waiting.isEmpty {
            fputs("[heard] waiting to exclude when launched: \(waiting.joined(separator: ", "))\n", stderr)
        }
    }
}

private actor ApplicationFilterCoordinator {
    weak var capture: SystemAudioCapture?

    init(capture: SystemAudioCapture) {
        self.capture = capture
    }

    func refresh(
        generation: Int,
        bundleIdentifier: String?,
        processID: pid_t?,
        expectedRunning: Bool?
    ) async {
        for _ in 0..<30 {
            guard let capture else { return }
            do {
                if try await capture.refreshApplicationFilter(
                    generation: generation,
                    bundleIdentifier: bundleIdentifier,
                    processID: processID,
                    expectedRunning: expectedRunning
                ) { return }
            } catch {
                // ScreenCaptureKit may lag behind an application lifecycle notification.
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        capture?.filterRefreshFailed()
    }
}
