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

        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if let state = RuntimeState.load(), state.pid == process.processIdentifier {
                print("\(state.status) (pid \(state.pid))")
                print(HeardPaths.memory.path)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        guard process.isRunning else {
            throw HeardError("heard exited while starting. See \(HeardPaths.log.path)")
        }
        print("starting (pid \(process.processIdentifier)); models may still be loading")
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

struct SystemAudioBatch: Sendable {
    let samples: [Float]
    let filterGeneration: Int
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
            v: 1, type: "session_start", ts: Date(), session: session,
            detail: requestedSystemAudio ? "microphone+system" : "microphone"
        ))

        let vad = try await VadManager()
        let systemGeneration = SystemAudioGeneration()
        let pipeline = try await TranscriptionPipeline(
            store: store,
            session: session,
            enableDiarization: requestedSystemAudio,
            systemAudioGeneration: systemGeneration
        )
        let micStream = AsyncStream<[Float]> { continuation in
            self.micContinuation = continuation
        }
        let systemStream = AsyncStream<SystemAudioBatch> { continuation in
            self.systemContinuation = continuation
        }
        let micChunker = await SpeechChunker(source: "microphone", vad: vad) { chunk in
            await pipeline.transcribe(chunk)
        }
        let systemChunker = await SpeechChunker(
            source: "system",
            vad: vad,
            filterGeneration: systemGeneration.value()
        ) { chunk in
            await pipeline.transcribe(chunk)
        }

        let micTask = Task {
            for await samples in micStream where !(await gate.paused) { await micChunker.accept(samples) }
        }
        let systemTask = Task {
            for await batch in systemStream {
                guard systemGeneration.accepts(batch.filterGeneration), !(await gate.paused) else { continue }
                await systemChunker.accept(batch.samples, filterGeneration: batch.filterGeneration)
            }
        }

        let microphone = MicrophoneCapture { [weak self] samples in
            health.recordMicrophone()
            self?.micContinuation?.yield(samples)
        }
        try await microphone.start()
        try await store.append(MemoryEvent(
            v: 1, type: "capture_ready", ts: Date(), session: session,
            source: "microphone", detail: "live audio callbacks started"
        ))
        var systemAudio: SystemAudioCapture?
        if requestedSystemAudio {
            let capture = SystemAudioCapture(
                excludedBundleIdentifiers: excludedApps,
                onFilterChange: {
                    await systemChunker.reset(filterGeneration: systemGeneration.value())
                },
                onFilterInvalidated: { generation in
                    systemGeneration.update(to: generation)
                    Task { await systemChunker.reset(filterGeneration: generation) }
                },
                onFilterState: { error in health.recordSystemAudioState(error: error) }
            ) { [weak self] samples, generation in
                health.recordSystemAudio()
                self?.systemContinuation?.yield(SystemAudioBatch(
                    samples: samples,
                    filterGeneration: generation
                ))
            }
            do {
                try await capture.start()
                systemAudio = capture
                state.captureSystemAudio = true
            } catch {
                state.systemAudioError = error.localizedDescription
                try await store.append(MemoryEvent(
                    v: 1, type: "warning", ts: Date(), session: session,
                    detail: "system audio unavailable: \(error.localizedDescription)"
                ))
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

        microphone.stop()
        healthTask.cancel()
        await systemAudio?.stop()
        micContinuation?.finish()
        systemContinuation?.finish()
        _ = await (micTask.result, systemTask.result)
        await micChunker.flush()
        await systemChunker.flush()
        try await store.append(MemoryEvent(v: 1, type: "session_stop", ts: Date(), session: session))
        memoryStore = nil
        activeSession = nil
        state.status = "stopped"
        state.updatedAt = Date()
        try state.save()
    }

    private var micContinuation: AsyncStream<[Float]>.Continuation?
    private var systemContinuation: AsyncStream<SystemAudioBatch>.Continuation?

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
