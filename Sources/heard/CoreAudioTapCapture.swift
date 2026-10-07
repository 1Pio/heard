@preconcurrency import AVFoundation
@preconcurrency import AppKit
@preconcurrency import CoreAudio
import Foundation

/// A global, unmuted process tap captures the Mac's output mix without a
/// display or per-app selection. The microphone remains a separate source.
@available(macOS 14.2, *)
final class CoreAudioTapCapture: @unchecked Sendable {
    private struct Buffer: Sendable {
        let channels: Int
        let data: Data
    }

    private let onSamples: @Sendable ([Float], Int) -> Void
    private let onFilterInvalidated: @Sendable (Int) -> Void
    private let onState: @Sendable (String?) -> Void
    private let excludedBundleIdentifiers: Set<String>
    private let lifecycleQueue = DispatchQueue(label: "heard.coreaudio-tap.lifecycle", qos: .userInitiated)
    private let processingQueue = DispatchQueue(label: "heard.coreaudio-tap.process", qos: .userInitiated)
    private let ioQueue = DispatchQueue(label: "heard.coreaudio-tap.io", qos: .userInitiated)
    private let converter = Mono16kConverter()
    private let lock = NSLock()
    private var running = false
    private var active = false
    private var filterGeneration = 0
    private var applicationObservers: [NSObjectProtocol] = []
    private var audioProcessObserver: AudioObjectPropertyListenerBlock?
    private var excludedAudioProcesses: Set<AudioObjectID> = []
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioDeviceID = kAudioObjectUnknown
    private var ioProc: AudioDeviceIOProcID?
    private var ioBlock: AudioDeviceIOBlock?
    private var format = AudioStreamBasicDescription()

    init(excludedBundleIdentifiers: [String] = [],
         onFilterInvalidated: @escaping @Sendable (Int) -> Void = { _ in },
         onState: @escaping @Sendable (String?) -> Void = { _ in },
         onSamples: @escaping @Sendable ([Float], Int) -> Void) {
        self.excludedBundleIdentifiers = Set(excludedBundleIdentifiers.map { $0.lowercased() })
        self.onFilterInvalidated = onFilterInvalidated
        self.onState = onState
        self.onSamples = onSamples
    }

    func start() throws {
        try lifecycleQueue.sync { try startCapture() }
        lock.withLock { active = true }
        installApplicationObservers()
    }

    private func startCapture() throws {
        guard !lock.withLock({ running }) else { return }
        guard let ownProcess = Self.processObject(for: getpid()) else {
            throw HeardError("Core Audio could not identify Heard for system-audio exclusion")
        }
        let excludedApplications = NSWorkspace.shared.runningApplications.filter { application in
            guard let identifier = application.bundleIdentifier?.lowercased(),
                  Self.isExcluded(bundleIdentifier: identifier, identifiers: excludedBundleIdentifiers) else { return false }
            return true
        }
        let excludedProcesses = try excludedApplications.map { application -> AudioObjectID in
            guard let object = Self.processObject(for: application.processIdentifier) else {
                throw HeardError("Core Audio could not safely exclude \(application.bundleIdentifier ?? "an app") yet")
            }
            return object
        }
        // Browser audio services can be absent from NSWorkspace's application list.
        // Match Core Audio's own process objects so every configured helper is excluded.
        let audioProcesses = try Self.processObjects(matching: excludedBundleIdentifiers)
        lock.withLock { excludedAudioProcesses = Set(audioProcesses) }
        let allExcludedProcesses = Array(Set([ownProcess] + excludedProcesses + audioProcesses))
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: allExcludedProcesses)
        description.name = "Heard System Audio"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        do {
            try Self.check(AudioHardwareCreateProcessTap(description, &tapID), "create system-audio tap")
            guard tapID != kAudioObjectUnknown else { throw HeardError("Core Audio returned no system-audio tap") }
            func aggregate(_ uid: String) -> NSDictionary {
                [
                    kAudioAggregateDeviceNameKey: "Heard System Audio",
                    kAudioAggregateDeviceUIDKey: uid,
                    kAudioAggregateDeviceIsPrivateKey: true,
                    kAudioAggregateDeviceTapListKey: [[
                        kAudioSubTapUIDKey: description.uuid.uuidString,
                        kAudioSubTapDriftCompensationKey: true
                    ]],
                    kAudioAggregateDeviceTapAutoStartKey: true
                ]
            }
            // Private aggregate devices can survive a crashed client without
            // appearing in normal enumeration. Bound their HAL identities.
            let primary = aggregate("com.local.heard.system-audio-tap")
            var aggregateStatus = AudioHardwareCreateAggregateDevice(primary as CFDictionary, &aggregateID)
            if aggregateStatus != noErr || aggregateID == kAudioObjectUnknown {
                aggregateID = kAudioObjectUnknown
                let fallback = aggregate("com.local.heard.system-audio-tap-fallback")
                aggregateStatus = AudioHardwareCreateAggregateDevice(fallback as CFDictionary, &aggregateID)
            }
            try Self.check(aggregateStatus, "create system-audio device")
            guard aggregateID != kAudioObjectUnknown else { throw HeardError("Core Audio returned no system-audio device") }
            var address = AudioObjectPropertyAddress(
                mSelector: kAudioTapPropertyFormat,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            try Self.check(AudioObjectGetPropertyData(tapID, &address, 0, nil, &size, &format),
                           "read system-audio format")
            guard format.mSampleRate > 0, format.mChannelsPerFrame > 0 else {
                throw HeardError("Core Audio returned an invalid system-audio format")
            }

            let block: AudioDeviceIOBlock = { [weak self] _, input, _, _, _ in
                guard let self, let generation = self.lock.withLock({ self.running ? self.filterGeneration : nil }) else { return }
                let list = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
                let buffers = list.compactMap { item -> Buffer? in
                    guard let bytes = item.mData, item.mDataByteSize > 0 else { return nil }
                    return Buffer(channels: Int(item.mNumberChannels),
                                  data: Data(bytes: bytes, count: Int(item.mDataByteSize)))
                }
                guard !buffers.isEmpty else { return }
                self.processingQueue.async { [weak self] in self?.process(buffers, generation: generation) }
            }
            var proc: AudioDeviceIOProcID?
            try Self.check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregateID, ioQueue, block),
                           "create system-audio IO process")
            guard let proc else { throw HeardError("Core Audio returned no system-audio IO process") }
            ioProc = proc
            ioBlock = block
            lock.withLock { running = true }
            try Self.check(AudioDeviceStart(aggregateID, proc), "start system-audio tap")
        } catch {
            tearDownCapture()
            throw error
        }
    }

    func stop() {
        lock.withLock { active = false; running = false }
        removeApplicationObservers()
        lifecycleQueue.sync { tearDownCapture() }
    }

    private func tearDownCapture() {
        lock.withLock { running = false }
        if let ioProc {
            let stopped = AudioDeviceStop(aggregateID, ioProc)
            let destroyed = AudioDeviceDestroyIOProcID(aggregateID, ioProc)
            if stopped != noErr || destroyed != noErr {
                fputs("[heard] Core Audio IO cleanup failed (stop=\(stopped), destroy=\(destroyed))\n", stderr)
            }
            self.ioProc = nil
            ioBlock = nil
        }
        processingQueue.sync {}
        if aggregateID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyAggregateDevice(aggregateID)
            if status != noErr { fputs("[heard] Core Audio aggregate cleanup failed (\(status))\n", stderr) }
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            let status = AudioHardwareDestroyProcessTap(tapID)
            if status != noErr { fputs("[heard] Core Audio tap cleanup failed (\(status))\n", stderr) }
            tapID = kAudioObjectUnknown
        }
    }

    private func installApplicationObservers() {
        guard !excludedBundleIdentifiers.isEmpty else { return }
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            applicationObservers.append(center.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                guard let self,
                      let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      let identifier = application.bundleIdentifier?.lowercased(),
                      Self.isExcluded(bundleIdentifier: identifier, identifiers: self.excludedBundleIdentifiers) else { return }
                self.invalidateAndRefresh()
            })
        }
        var address = Self.audioProcessListAddress
        let observer: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshAudioProcessExclusions()
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                &address, lifecycleQueue, observer) == noErr {
            audioProcessObserver = observer
        }
        lifecycleQueue.async { [weak self] in self?.refreshAudioProcessExclusions() }
    }

    private func refreshAudioProcessExclusions() {
        guard lock.withLock({ active && running }) else { return }
        do {
            let current = Set(try Self.processObjects(matching: excludedBundleIdentifiers))
            if lock.withLock({ current != excludedAudioProcesses }) { invalidateAndRefresh() }
        } catch { invalidateAndRefresh() }
    }

    private func removeApplicationObservers() {
        let center = NSWorkspace.shared.notificationCenter
        for observer in applicationObservers { center.removeObserver(observer) }
        applicationObservers.removeAll()
        if let audioProcessObserver {
            var address = Self.audioProcessListAddress
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),
                                                   &address, lifecycleQueue, audioProcessObserver)
            self.audioProcessObserver = nil
        }
    }

    private func invalidateAndRefresh() {
        let generation = lock.withLock { () -> Int? in
            guard active else { return nil }
            running = false
            filterGeneration &+= 1
            return filterGeneration
        }
        guard let generation else { return }
        onFilterInvalidated(generation)
        onState("system audio exclusion updating")
        lifecycleQueue.async { [weak self] in
            guard let self, self.lock.withLock({ self.active }) else { return }
            self.tearDownCapture()
            for attempt in 0..<10 {
                guard self.lock.withLock({ self.active }) else { return }
                if attempt > 0 { Thread.sleep(forTimeInterval: 0.5) }
                do {
                    try self.startCapture()
                    self.onState(nil)
                    return
                } catch {
                    if attempt == 9 { self.onState("system audio exclusion refresh failed: \(error.localizedDescription)") }
                }
            }
        }
    }

    private func process(_ buffers: [Buffer], generation: Int) {
        guard lock.withLock({ running && filterGeneration == generation }) else { return }
        let flags = format.mFormatFlags
        let float32 = flags & kAudioFormatFlagIsFloat != 0 && format.mBitsPerChannel == 32
        let int16 = flags & kAudioFormatFlagIsFloat == 0 && format.mBitsPerChannel == 16
        guard float32 || int16 else { return }
        let nonInterleaved = flags & kAudioFormatFlagIsNonInterleaved != 0
        var mono: [Float] = []
        var channelsMixed = 0
        for item in buffers {
            let channels = nonInterleaved ? max(1, item.channels) : max(item.channels, Int(format.mChannelsPerFrame))
            let values: [Float] = item.data.withUnsafeBytes { raw in
                if float32 { return Array(raw.bindMemory(to: Float.self)) }
                return raw.bindMemory(to: Int16.self).map { Float($0) / 32768 }
            }
            let frameCount = values.count / channels
            guard frameCount > 0 else { continue }
            if mono.isEmpty { mono = [Float](repeating: 0, count: frameCount) }
            for frame in 0..<min(frameCount, mono.count) {
                for channel in 0..<channels { mono[frame] += values[frame * channels + channel] }
            }
            channelsMixed += channels
        }
        guard channelsMixed > 0, !mono.isEmpty else { return }
        for index in mono.indices { mono[index] /= Float(channelsMixed) }
        guard let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                              sampleRate: format.mSampleRate,
                                              channels: 1, interleaved: false),
              let input = AVAudioPCMBuffer(pcmFormat: inputFormat,
                                           frameCapacity: AVAudioFrameCount(mono.count)),
              let channel = input.floatChannelData?[0] else { return }
        input.frameLength = AVAudioFrameCount(mono.count)
        channel.update(from: mono, count: mono.count)
        let converted = converter.convert(input)
        if !converted.isEmpty { onSamples(converted, generation) }
    }

    static func isExcluded(bundleIdentifier: String, identifiers: Set<String>) -> Bool {
        let bundle = bundleIdentifier.lowercased()
        return identifiers.contains { bundle == $0 || bundle.hasPrefix($0 + ".") }
    }

    private static var audioProcessListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjects(matching identifiers: Set<String>) throws -> [AudioObjectID] {
        guard !identifiers.isEmpty else { return [] }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        try check(AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),
                                                 &address, 0, nil, &size), "list audio processes")
        guard size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes { buffer in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                       &address, 0, nil, &size, buffer.baseAddress!)
        }
        try check(status, "read audio processes")
        return objects.prefix(Int(size) / MemoryLayout<AudioObjectID>.size).filter { object in
            var bundleAddress = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyBundleID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            let identifier = UnsafeMutablePointer<CFString?>.allocate(capacity: 1)
            identifier.initialize(to: nil)
            defer { identifier.deinitialize(count: 1); identifier.deallocate() }
            var bundleSize = UInt32(MemoryLayout<CFString?>.size)
            let result = AudioObjectGetPropertyData(object, &bundleAddress, 0, nil, &bundleSize, identifier)
            guard result == noErr, let bundle = identifier.pointee else { return false }
            return isExcluded(bundleIdentifier: bundle as String, identifiers: identifiers)
        }
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var object = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &address, UInt32(MemoryLayout<pid_t>.size),
                                                &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }

    private static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw HeardError("Core Audio could not \(action) (status \(status))") }
    }
}
