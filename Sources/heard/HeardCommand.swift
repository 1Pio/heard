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
            let unknown = arguments.dropFirst().filter { $0 != "--mic-only" && $0 != "--foreground" }
            guard unknown.isEmpty else { throw HeardError("Unknown start option: \(unknown[0])") }
            try await start(
                systemAudio: !arguments.contains("--mic-only"),
                foreground: arguments.contains("--foreground")
            )
        case "pause": try pause()
        case "stop": try stop()
        case "status": status()
        case "forget": try forget(Array(arguments.dropFirst()))
        case "_run":
            try await HeardDaemon(captureSystemAudio: !arguments.contains("--mic-only")).run()
        case "help", "--help", "-h": printHelp()
        default: throw HeardError("Unknown command '\(command)'. Run `heard help`.")
        }
    }

    private static func start(systemAudio: Bool, foreground: Bool) async throws {
        try HeardPaths.prepare()
        if let state = RuntimeState.load(), state.isAlive {
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
            try await HeardDaemon(captureSystemAudio: systemAudio).run()
            return
        }

        guard let executable = Bundle.main.executableURL else {
            throw HeardError("Could not resolve the heard executable path.")
        }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["_run"] + (systemAudio ? [] : ["--mic-only"])
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
    }

    private static func forget(_ arguments: [String]) throws {
        guard arguments.count == 2, arguments[0] == "--before" else {
            throw HeardError("Usage: heard forget --before 2026-07-12T12:00:00Z")
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
          heard forget --before TIME explicitly delete records older than ISO 8601 TIME

        `heard start` captures microphone and system audio. The only optional mode,
        `--mic-only`, avoids the system-audio permission. Nothing is ever pruned
        automatically. Set HEARD_HOME to move the data directory.
        """)
    }
}

actor RunGate {
    private(set) var paused = false
    func pause() { paused = true }
    func resume() { paused = false }
}

final class HeardDaemon: @unchecked Sendable {
    private let requestedSystemAudio: Bool
    private let gate = RunGate()
    private var state: RuntimeState
    private var signalSources: [DispatchSourceSignal] = []
    private let controlLock = NSLock()
    private var finishContinuation: CheckedContinuation<Void, Never>?
    private var stopRequested = false
    private var memoryStore: MemoryStore?
    private var activeSession: String?

    init(captureSystemAudio: Bool) {
        requestedSystemAudio = captureSystemAudio
        let now = Date()
        state = RuntimeState(
            pid: getpid(), status: "starting", startedAt: now, updatedAt: now,
            captureSystemAudio: false, lastError: nil,
            requestedSystemAudio: captureSystemAudio, systemAudioError: nil
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
        let pipeline = try await TranscriptionPipeline(
            store: store, session: session, enableDiarization: requestedSystemAudio
        )
        let micStream = AsyncStream<[Float]> { continuation in
            self.micContinuation = continuation
        }
        let systemStream = AsyncStream<[Float]> { continuation in
            self.systemContinuation = continuation
        }
        let micChunker = await SpeechChunker(source: "microphone", vad: vad) { chunk in
            await pipeline.transcribe(chunk)
        }
        let systemChunker = await SpeechChunker(source: "system", vad: vad) { chunk in
            await pipeline.transcribe(chunk)
        }

        let micTask = Task {
            for await samples in micStream where !(await gate.paused) { await micChunker.accept(samples) }
        }
        let systemTask = Task {
            for await samples in systemStream where !(await gate.paused) { await systemChunker.accept(samples) }
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
            let capture = SystemAudioCapture { [weak self] samples in
                health.recordSystemAudio()
                self?.systemContinuation?.yield(samples)
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
    private var systemContinuation: AsyncStream<[Float]>.Continuation?

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
