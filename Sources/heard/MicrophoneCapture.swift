@preconcurrency import AVFoundation
@preconcurrency import CoreAudio
import Foundation

struct MicrophoneInputFormat: Equatable, Sendable {
    let sampleRate: Double
    let channelCount: UInt32

    var isUsable: Bool { sampleRate > 0 && channelCount > 0 }
}

final class MicrophoneObservation: @unchecked Sendable {
    let token: NSObjectProtocol
    init(_ token: NSObjectProtocol) { self.token = token }
}

protocol MicrophoneInputEngine: AnyObject, Sendable {
    var inputFormat: MicrophoneInputFormat { get }
    func installTap(
        generation: Int,
        handler: @escaping @Sendable ([Float], Int) -> Void
    )
    func observeConfigurationChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> MicrophoneObservation
    func removeConfigurationObserver(_ observation: MicrophoneObservation)
    func prepare()
    func start() throws
    func stop()
    func removeTap()
}

final class AVAudioMicrophoneEngine: MicrophoneInputEngine, @unchecked Sendable {
    private let engine = AVAudioEngine()
    private let converter = Mono16kConverter()
    private let lock = NSLock()
    private var tapInstalled = false

    var inputFormat: MicrophoneInputFormat {
        let format = engine.inputNode.outputFormat(forBus: 0)
        return MicrophoneInputFormat(
            sampleRate: format.sampleRate,
            channelCount: format.channelCount
        )
    }

    func installTap(
        generation: Int,
        handler: @escaping @Sendable ([Float], Int) -> Void
    ) {
        lock.withLock { tapInstalled = true }
        engine.inputNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { [converter] buffer, _ in
            let samples = converter.convert(buffer)
            if !samples.isEmpty { handler(samples, generation) }
        }
    }

    func observeConfigurationChanges(
        _ handler: @escaping @Sendable () -> Void
    ) -> MicrophoneObservation {
        MicrophoneObservation(NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: nil
        ) { _ in handler() })
    }

    func removeConfigurationObserver(_ observation: MicrophoneObservation) {
        NotificationCenter.default.removeObserver(observation.token)
    }

    func prepare() { engine.prepare() }
    func start() throws { try engine.start() }
    func stop() { engine.stop() }

    func removeTap() {
        let installed = lock.withLock { () -> Bool in
            guard tapInstalled else { return false }
            tapInstalled = false
            return true
        }
        if installed { engine.inputNode.removeTap(onBus: 0) }
    }
}

final class MicrophoneGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    func value() -> Int { lock.withLock { current } }

    func advance() -> Int {
        lock.withLock {
            current &+= 1
            return current
        }
    }

    func accepts(_ generation: Int) -> Bool {
        lock.withLock { current == generation }
    }
}

actor MicrophoneLifecycle {
    typealias EngineFactory = @Sendable () -> any MicrophoneInputEngine
    typealias RetrySleep = @Sendable (Duration) async -> Void

    private struct ActiveEngine {
        let engine: any MicrophoneInputEngine
        let observation: MicrophoneObservation
    }

    nonisolated let generation = MicrophoneGeneration()
    private let engineFactory: EngineFactory
    private let retryDelays: [Duration]
    private let retrySleep: RetrySleep
    private let onSamples: @Sendable ([Float]) -> Void
    private nonisolated let onState: @Sendable (String?) -> Void
    private var active: ActiveEngine?
    private var desiredRunning = false
    private var recoveryID = 0
    private var recoveryTask: Task<Void, Never>?

    init(
        engineFactory: @escaping EngineFactory = { AVAudioMicrophoneEngine() },
        retryDelays: [Duration] = [
            .milliseconds(100), .milliseconds(250), .milliseconds(500),
            .seconds(1), .seconds(2)
        ],
        retrySleep: @escaping RetrySleep = { duration in
            try? await Task.sleep(for: duration)
        },
        onState: @escaping @Sendable (String?) -> Void = { _ in },
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) {
        self.engineFactory = engineFactory
        self.retryDelays = retryDelays
        self.retrySleep = retrySleep
        self.onState = onState
        self.onSamples = onSamples
    }

    func start() throws {
        guard !desiredRunning else { return }
        desiredRunning = true
        do {
            try rebuild(generation: generation.value())
            onState(nil)
        } catch {
            desiredRunning = false
            tearDownActiveEngine()
            throw error
        }
    }

    nonisolated func invalidateAndRecover(reason: String) {
        let invalidatedGeneration = generation.advance()
        onState("reconfiguring after \(reason)")
        Task { await enqueueRecovery(generation: invalidatedGeneration) }
    }

    func stop() {
        desiredRunning = false
        recoveryID &+= 1
        recoveryTask?.cancel()
        recoveryTask = nil
        _ = generation.advance()
        tearDownActiveEngine()
    }

    func enqueueRecovery(generation: Int) {
        guard desiredRunning, self.generation.accepts(generation) else { return }
        recoveryID &+= 1
        let id = recoveryID
        recoveryTask?.cancel()
        recoveryTask = Task { [weak self] in
            await self?.recover(id: id, initialGeneration: generation)
        }
    }

    private func recover(id: Int, initialGeneration: Int) async {
        var attemptGeneration = initialGeneration
        let delays = [Duration.zero] + retryDelays
        var lastError: Error?

        for (index, delay) in delays.enumerated() {
            if delay > .zero { await retrySleep(delay) }
            guard !Task.isCancelled, desiredRunning, recoveryID == id else { return }
            guard generation.value() == attemptGeneration else { return }
            do {
                try rebuild(generation: attemptGeneration)
                onState(nil)
                recoveryTask = nil
                return
            } catch {
                lastError = error
                if index < delays.count - 1 {
                    attemptGeneration = generation.advance()
                }
            }
        }

        let detail = lastError?.localizedDescription ?? "unknown audio-device error"
        onState("recovery failed: \(detail)")
        recoveryTask = nil
    }

    private func rebuild(generation: Int) throws {
        tearDownActiveEngine()
        guard desiredRunning, self.generation.accepts(generation) else {
            throw HeardError("Microphone recovery was superseded.")
        }

        let engine = engineFactory()
        let format = engine.inputFormat
        guard format.isUsable else {
            engine.stop()
            throw HeardError("No usable default microphone is currently available.")
        }

        let output = onSamples
        engine.installTap(generation: generation) { [sampleGeneration = self.generation] samples, callbackGeneration in
            guard sampleGeneration.accepts(callbackGeneration) else { return }
            output(samples)
        }
        let observation = engine.observeConfigurationChanges { [weak self] in
            self?.invalidateAndRecover(reason: "audio-device configuration change")
        }

        do {
            engine.prepare()
            try engine.start()
            active = ActiveEngine(engine: engine, observation: observation)
        } catch {
            engine.removeConfigurationObserver(observation)
            engine.stop()
            engine.removeTap()
            throw error
        }
    }

    private func tearDownActiveEngine() {
        guard let active else { return }
        self.active = nil
        active.engine.removeConfigurationObserver(active.observation)
        active.engine.stop()
        active.engine.removeTap()
    }
}

final class AudioInputDeviceMonitor: @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "heard.microphone.devices", qos: .utility)
    private var listener: AudioObjectPropertyListenerBlock?
    private var addresses: [AudioObjectPropertyAddress] = []

    func start(onChange: @escaping @Sendable () -> Void) throws {
        try lock.withLock {
            guard listener == nil else { return }
            let block: AudioObjectPropertyListenerBlock = { _, _ in onChange() }
            let selectors: [AudioObjectPropertySelector] = [
                kAudioHardwarePropertyDefaultInputDevice,
                kAudioHardwarePropertyDevices
            ]
            var installed: [AudioObjectPropertyAddress] = []
            for selector in selectors {
                var address = AudioObjectPropertyAddress(
                    mSelector: selector,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                let status = AudioObjectAddPropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, queue, block
                )
                guard status == noErr else {
                    for var previous in installed {
                        AudioObjectRemovePropertyListenerBlock(
                            AudioObjectID(kAudioObjectSystemObject), &previous, queue, block
                        )
                    }
                    throw HeardError("Could not monitor microphone devices (Core Audio error \(status)).")
                }
                installed.append(address)
            }
            addresses = installed
            listener = block
        }
    }

    func stop() {
        lock.withLock {
            guard let listener else { return }
            for var address in addresses {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &address, queue, listener
                )
            }
            addresses.removeAll()
            self.listener = nil
        }
    }
}

final class MicrophoneCapture: @unchecked Sendable {
    private let lifecycle: MicrophoneLifecycle
    private let deviceMonitor = AudioInputDeviceMonitor()

    init(
        onState: @escaping @Sendable (String?) -> Void = { _ in },
        onSamples: @escaping @Sendable ([Float]) -> Void
    ) {
        lifecycle = MicrophoneLifecycle(onState: onState, onSamples: onSamples)
    }

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

        try deviceMonitor.start { [lifecycle] in
            lifecycle.invalidateAndRecover(reason: "default input device change")
        }
        do {
            try await lifecycle.start()
        } catch {
            deviceMonitor.stop()
            throw error
        }
    }

    func stop() async {
        deviceMonitor.stop()
        await lifecycle.stop()
    }
}
