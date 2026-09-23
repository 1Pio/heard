import Darwin
import FluidAudio
import Foundation

@main
struct HeardCommand {
    static func main() async {
        do {
            try await run(Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("heard: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    static func run(_ arguments: [String]) async throws {
        let command = arguments.first ?? "status"
        switch command {
        case "start":
            let options = try StartOptions.parse(Array(arguments.dropFirst()), allowForeground: true)
            let configuration = try HeardConfiguration.load()
            let excludedApps = try HeardConfiguration.merged(
                configured: configuration.excludedApps,
                commandLine: options.excludedApps
            )
            try await start(
                systemAudio: !options.micOnly,
                foreground: options.foreground,
                excludedApps: excludedApps
            )
        case "pause": try pause()
        case "stop": try stop()
        case "status": status()
        case "follow":
            try await MemoryFollower.follow(options: FollowOptions.parse(Array(arguments.dropFirst())))
        case "replay":
            try await RecordingReplay.run(Array(arguments.dropFirst()))
        case "forget": try forget(Array(arguments.dropFirst()))
        case "_run":
            let options = try StartOptions.parse(Array(arguments.dropFirst()), allowForeground: false)
            try await HeardDaemon(
                captureSystemAudio: !options.micOnly,
                excludedApps: options.excludedApps
            ).run()
        case "help", "--help", "-h": printHelp()
        default: throw HeardError("Unknown command '\(command)'. Run `heard help`.")
        }
    }

    private static func start(systemAudio: Bool, foreground: Bool, excludedApps: [String]) async throws {
        try HeardPaths.prepare()
        if let state = RuntimeState.load(), state.isAlive {
            let activeExcludedApps = state.excludedApps ?? []
            guard state.requestedSystemAudio == systemAudio, activeExcludedApps == excludedApps else {
                throw HeardError("heard is already running with different capture options. Run `heard stop`, then start it again.")
            }
            if state.status == "paused" {
                guard kill(state.pid, SIGUSR2) == 0 else { throw HeardError("Could not resume heard.") }
                print("resumed")
            } else {
                print("already \(state.status); no restart was performed")
                for line in StatusFormatter.lines(state: state, health: CaptureHealthSnapshot.load()) {
                    print(line)
                }
            }
            print(HeardPaths.memory.path)
            return
        }

        // Fail at the caller with a useful setup error, including GUI launchers.
        // The secret remains in memory and is never passed as a process argument.
        _ = try ElevenLabsCredential.load()

        if foreground {
            try await HeardDaemon(captureSystemAudio: systemAudio, excludedApps: excludedApps).run()
            return
        }

        guard let executable = Bundle.main.executableURL else {
            throw HeardError("Could not resolve the heard executable path.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["_run"]
            + (systemAudio ? [] : ["--mic-only"])
            + excludedApps.flatMap { ["--exclude-app", $0] }
        process.environment = ProcessInfo.processInfo.environment
        let log = FileManager.default.fileExists(atPath: HeardPaths.log.path)
            ? try FileHandle(forWritingTo: HeardPaths.log)
            : {
                FileManager.default.createFile(atPath: HeardPaths.log.path, contents: nil)
                return try! FileHandle(forWritingTo: HeardPaths.log)
            }()
        try log.seekToEnd()
        process.standardOutput = log
        process.standardError = log
        try process.run()

        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if let state = RuntimeState.load(), state.pid == process.processIdentifier,
               state.status == "running" || state.status == "paused" {
                print("\(state.status) (pid \(state.pid))")
                print(HeardPaths.memory.path)
                return
            }
            if !process.isRunning { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard process.isRunning else {
            throw HeardError("heard exited while starting. See \(HeardPaths.log.path)")
        }
        print("starting (pid \(process.processIdentifier)); check `heard status` for capture readiness")
        print(HeardPaths.memory.path)
    }

    private static func pause() throws {
        guard let state = RuntimeState.load(), state.isAlive else { throw HeardError("heard is not running.") }
        guard state.status != "paused" else { print("already paused"); return }
        guard kill(state.pid, SIGUSR1) == 0 else { throw HeardError("Could not pause heard.") }
        print("paused")
    }

    private static func stop() throws {
        guard let state = RuntimeState.load(), state.isAlive else { print("already stopped"); return }
        guard kill(state.pid, SIGTERM) == 0 else { throw HeardError("Could not stop heard.") }
        print("stopping")
    }

    private static func status() {
        if let state = RuntimeState.load(), state.isAlive {
            for line in StatusFormatter.lines(state: state, health: CaptureHealthSnapshot.load()) {
                print(line)
            }
            if let error = state.lastError { print("error: \(error)") }
        } else {
            print("stopped")
        }
        print("memory: \(HeardPaths.memory.path)")
        print("log: \(HeardPaths.log.path)")
        print("config: \(HeardPaths.config.path)")
    }

    private static func forget(_ arguments: [String]) throws {
        if arguments == ["--all"] {
            let result = try MemoryMaintenance.forgetAll()
            print("deleted \(result.removed) records; kept 0")
            return
        }
        guard arguments.count == 2, arguments[0] == "--before" else {
            throw HeardError("Usage: heard forget --before TIME | heard forget --all")
        }
        guard let cutoff = ISOTime.parse(arguments[1]) else {
            throw HeardError("Invalid timestamp. Use ISO 8601, for example 2026-07-12T12:00:00Z.")
        }
        let result = try MemoryMaintenance.forget(before: cutoff)
        print("deleted \(result.removed) records; kept \(result.kept)")
    }

    private static func printHelp() {
        print("""
        heard: a local, append-only live speech memory

          heard start [--mic-only]   start in the background; also resumes
          heard pause                pause without unloading models
          heard stop                 flush and stop
          heard status               show state and memory path
          heard follow [--simple] [--since 5m]
                                     show the live memory log
          heard replay --file PATH [--start SECONDS] [--duration SECONDS] [--source microphone|system]
                                     stream a recording through Scribe at live speed
          heard forget --before TIME explicitly delete records older than ISO 8601 TIME
          heard forget --all         explicitly delete every memory record

        Start options:
          --mic-only                 capture only the microphone
          --exclude-app BUNDLE_ID    exclude an app's system audio; repeatable

        `heard start` captures microphone and system audio. `--mic-only` avoids
        the system-audio permission. Persistent app exclusions belong in the
        config file shown by `heard status`. Nothing is ever pruned automatically.
        Set HEARD_HOME to move the data directory.
        """)
    }
}

struct StartOptions: Equatable {
    let micOnly: Bool
    let foreground: Bool
    let excludedApps: [String]

    static func parse(_ arguments: [String], allowForeground: Bool) throws -> Self {
        var micOnly = false
        var foreground = false
        var excludedApps: [String] = []
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "--mic-only":
                guard !micOnly else { throw HeardError("--mic-only may only be specified once.") }
                micOnly = true
                index += 1
            case "--foreground" where allowForeground:
                guard !foreground else { throw HeardError("--foreground may only be specified once.") }
                foreground = true
                index += 1
            case "--exclude-app":
                guard index + 1 < arguments.count, !arguments[index + 1].hasPrefix("--") else {
                    throw HeardError("--exclude-app requires an app bundle identifier such as com.apple.Music.")
                }
                excludedApps.append(arguments[index + 1])
                index += 2
            default:
                throw HeardError("Unknown start option: \(arguments[index])")
            }
        }
        return Self(micOnly: micOnly, foreground: foreground, excludedApps: excludedApps)
    }
}

actor RunGate {
    private(set) var paused = false
    func pause() { paused = true }
    func resume() { paused = false }
}

final class SystemAudioGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    func update(to generation: Int) {
        lock.withLock { current = generation }
    }

    func accepts(_ generation: Int) -> Bool {
        lock.withLock { current == generation }
    }

    func value() -> Int {
        lock.withLock { current }
    }

    func performIfCurrent<T>(
        _ generation: Int,
        _ operation: () throws -> T
    ) rethrows -> T? {
        lock.lock()
        defer { lock.unlock() }
        guard current == generation else { return nil }
        return try operation()
    }
}

final class HeardDaemon: @unchecked Sendable {
    private let requestedSystemAudio: Bool
    private let excludedApps: [String]
    private let gate = RunGate()
    private var state: RuntimeState
    private var signalSources: [DispatchSourceSignal] = []
    private let controlLock = NSLock()
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var stopRequested = false
    private var memoryStore: MemoryStore?
    private var activeSession: String?

    init(captureSystemAudio: Bool, excludedApps: [String] = []) {
        requestedSystemAudio = captureSystemAudio
        self.excludedApps = excludedApps
        let now = Date()
        state = RuntimeState(
            pid: getpid(), status: "starting", startedAt: now, updatedAt: now,
            captureSystemAudio: false, lastError: nil,
            requestedSystemAudio: captureSystemAudio, systemAudioError: nil,
            excludedApps: excludedApps
        )
    }

    func run() async throws {
        try HeardPaths.prepare()
        try state.save()
        installSignals()

        let store = try MemoryStore()
        let health = CaptureHealth()
        let session = UUID().uuidString.lowercased()
        memoryStore = store
        activeSession = session
        try await store.append(MemoryEvent(
            v: 2, type: "session_start", ts: Date(), session: session,
            detail: requestedSystemAudio ? "microphone+system; scribe_v2_realtime" : "microphone; scribe_v2_realtime"
        ))

        let micStream = AsyncStream<AudioBatch>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            self.micContinuation = continuation
        }
        let systemStream = AsyncStream<AudioBatch>(bufferingPolicy: .bufferingNewest(100)) { continuation in
            self.systemContinuation = continuation
        }
        let micTrack = try StreamingTrack(source: "microphone", session: session, store: store) {
            health.recordMicrophoneState(error: $0)
        }
        try await micTrack.start()
        let micTask = Task {
            for await batch in micStream where !(await gate.paused) {
                await micTrack.accept(batch)
            }
            await micTrack.finish()
        }

        let microphone = MicrophoneCapture(
            onState: { error in health.recordMicrophoneState(error: error) }
        ) { [weak self] samples in
            health.recordMicrophone()
            self?.micContinuation?.yield(AudioBatch(samples: samples, capturedAtEnd: Date()))
        }
        do { try await microphone.start() }
        catch {
            micContinuation?.finish()
            _ = await micTask.result
            throw error
        }
        try await store.append(MemoryEvent(
            v: 2, type: "capture_ready", ts: Date(), session: session,
            source: "microphone", detail: "microphone engine started; awaiting live audio callbacks"
        ))
        var stopCoreAudioTap: (() -> Void)?
        var systemAudioFallback: SystemAudioCapture?
        var systemTask: Task<Void, Never>?
        var systemHeartbeat: Task<Void, Never>?
        let systemFilterGeneration = SystemAudioGeneration()
        if requestedSystemAudio {
            do {
                if #available(macOS 14.2, *) {
                    let capture = CoreAudioTapCapture(
                        excludedBundleIdentifiers: excludedApps,
                        onFilterInvalidated: { systemFilterGeneration.update(to: $0) },
                        onState: { health.recordSystemAudioState(error: $0) }
                    ) { [weak self] samples, generation in
                        guard systemFilterGeneration.accepts(generation) else { return }
                        health.recordSystemAudio(samples: samples)
                        self?.systemContinuation?.yield(AudioBatch(samples: samples,
                                                                   capturedAtEnd: Date(), filterGeneration: generation))
                    }
                    try capture.start()
                    stopCoreAudioTap = { capture.stop() }
                } else {
                    throw HeardError("Core Audio system tap requires macOS 14.2")
                }
                state.captureSystemAudio = true
                try await store.append(MemoryEvent(v: 2, type: "capture_ready", ts: Date(), session: session,
                                                   source: "system", detail: "Core Audio global system tap started"))
            } catch {
                try await store.append(MemoryEvent(v: 2, type: "warning", ts: Date(), session: session,
                                                   source: "system", detail: "Core Audio tap unavailable; trying ScreenCaptureKit: \(error.localizedDescription)"))
                let fallback = SystemAudioCapture(excludedBundleIdentifiers: excludedApps,
                    onFilterInvalidated: { systemFilterGeneration.update(to: $0) },
                    onFilterState: { health.recordSystemAudioState(error: $0) }) { [weak self] samples, generation in
                    guard systemFilterGeneration.accepts(generation) else { return }
                    health.recordSystemAudio(samples: samples)
                    self?.systemContinuation?.yield(AudioBatch(samples: samples,
                                                               capturedAtEnd: Date(), filterGeneration: generation))
                }
                do {
                    try await fallback.start()
                    systemAudioFallback = fallback
                    state.captureSystemAudio = true
                    try await store.append(MemoryEvent(v: 2, type: "capture_ready", ts: Date(), session: session,
                                                       source: "system", detail: "ScreenCaptureKit fallback started"))
                } catch {
                    state.systemAudioError = error.localizedDescription
                    health.recordSystemAudioState(error: error.localizedDescription)
                    try await store.append(MemoryEvent(v: 2, type: "warning", ts: Date(), session: session,
                                                       source: "system", detail: "system audio unavailable: \(error.localizedDescription)"))
                }
            }
            if state.captureSystemAudio {
                let track = try StreamingTrack(source: "system", session: session, store: store) {
                    health.recordSystemAudioState(error: $0)
                }
                do { try await track.start() }
                catch {
                    stopCoreAudioTap?()
                    await systemAudioFallback?.stop()
                    await microphone.stop()
                    micContinuation?.finish()
                    _ = await micTask.result
                    throw error
                }
                systemTask = Task {
                    for await batch in systemStream where !(await gate.paused) || batch.synthetic {
                        if let generation = batch.filterGeneration,
                           !systemFilterGeneration.accepts(generation) { continue }
                        await track.accept(batch)
                    }
                    await track.finish()
                }
                // Core Audio taps may deliver no buffers during complete silence.
                // Keep Scribe's live socket and the source timeline moving.
                let startedHeartbeatAt = Date()
                let capturePID = state.pid
                systemHeartbeat = Task { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(for: .milliseconds(200))
                        if Task.isCancelled { break }
                        let last = health.snapshot(pid: capturePID).lastSystemAudioCallbackAt ?? startedHeartbeatAt
                        if Date().timeIntervalSince(last) > 0.35 {
                            self?.systemContinuation?.yield(AudioBatch(
                                samples: [Float](repeating: 0, count: 3_200),
                                capturedAtEnd: Date().addingTimeInterval(-0.1), synthetic: true))
                        }
                    }
                }
            }
        }
        state.status = await gate.paused ? "paused" : "running"
        state.updatedAt = Date()
        try state.save()
        health.write(pid: state.pid)
        let daemonPID = state.pid
        let healthTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { break }
                health.write(pid: daemonPID)
            }
        }

        await withCheckedContinuation { continuation in
            controlLock.lock()
            if stopRequested {
                controlLock.unlock()
                continuation.resume()
            } else {
                finishContinuation = continuation
                controlLock.unlock()
            }
        }

        await microphone.stop()
        healthTask.cancel()
        systemHeartbeat?.cancel()
        stopCoreAudioTap?()
        await systemAudioFallback?.stop()
        micContinuation?.finish()
        systemContinuation?.finish()
        _ = await micTask.result
        if let systemTask { _ = await systemTask.result }
        try await store.append(MemoryEvent(v: 2, type: "session_stop", ts: Date(), session: session))
        memoryStore = nil
        activeSession = nil
        state.status = "stopped"
        state.updatedAt = Date()
        try state.save()
    }

    private var micContinuation: AsyncStream<AudioBatch>.Continuation?
    private var systemContinuation: AsyncStream<AudioBatch>.Continuation?

    private func installSignals() {
        for number in [SIGUSR1, SIGUSR2, SIGTERM, SIGINT] { signal(number, SIG_IGN) }
        signalSources = [SIGUSR1, SIGUSR2, SIGTERM, SIGINT].map { number in
            let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                Task { await self.handleSignal(number) }
            }
            source.resume()
            return source
        }
    }

    private func handleSignal(_ number: Int32) async {
        switch number {
        case SIGUSR1:
            await gate.pause()
            state.status = "paused"
            if let memoryStore, let activeSession {
                try? await memoryStore.append(MemoryEvent(v: 1, type: "pause", ts: Date(), session: activeSession))
            }
        case SIGUSR2:
            await gate.resume()
            state.status = "running"
            if let memoryStore, let activeSession {
                try? await memoryStore.append(MemoryEvent(v: 1, type: "resume", ts: Date(), session: activeSession))
            }
        default:
            state.status = "stopping"
            let continuation = controlLock.withLock { () -> CheckedContinuation<Void, Never>? in
                stopRequested = true
                defer { finishContinuation = nil }
                return finishContinuation
            }
            continuation?.resume()
        }
        state.updatedAt = Date()
        try? state.save()
    }
}
