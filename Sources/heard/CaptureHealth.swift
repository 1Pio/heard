import Foundation

struct CaptureHealthSnapshot: Codable, Sendable {
    let pid: Int32
    let writtenAt: Date
    let microphoneCallbacks: UInt64
    let lastMicrophoneCallbackAt: Date?
    let systemAudioCallbacks: UInt64
    let lastSystemAudioCallbackAt: Date?

    static func load() -> Self? {
        guard let data = try? Data(contentsOf: HeardPaths.health) else { return nil }
        return try? JSONDecoder.heard.decode(Self.self, from: data)
    }
}

final class CaptureHealth: @unchecked Sendable {
    private struct Counters {
        var microphoneCallbacks: UInt64 = 0
        var lastMicrophoneCallbackAt: Date?
        var systemAudioCallbacks: UInt64 = 0
        var lastSystemAudioCallbackAt: Date?
    }

    private let lock = NSLock()
    private var counters = Counters()

    func recordMicrophone() {
        lock.withLock {
            counters.microphoneCallbacks &+= 1
            counters.lastMicrophoneCallbackAt = Date()
        }
    }

    func recordSystemAudio() {
        lock.withLock {
            counters.systemAudioCallbacks &+= 1
            counters.lastSystemAudioCallbackAt = Date()
        }
    }

    func snapshot(pid: Int32) -> CaptureHealthSnapshot {
        lock.withLock {
            CaptureHealthSnapshot(
                pid: pid,
                writtenAt: Date(),
                microphoneCallbacks: counters.microphoneCallbacks,
                lastMicrophoneCallbackAt: counters.lastMicrophoneCallbackAt,
                systemAudioCallbacks: counters.systemAudioCallbacks,
                lastSystemAudioCallbackAt: counters.lastSystemAudioCallbackAt
            )
        }
    }

    func write(pid: Int32) {
        guard let data = try? JSONEncoder.heard.encode(snapshot(pid: pid)) else { return }
        try? data.write(to: HeardPaths.health, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HeardPaths.health.path)
    }
}

enum StatusFormatter {
    static func lines(state: RuntimeState, health: CaptureHealthSnapshot?, now: Date = Date()) -> [String] {
        var lines = ["\(state.status) (pid \(state.pid))"]
        if state.status == "starting" {
            lines.append("microphone: initializing")
        } else if let health, health.pid == state.pid, let last = health.lastMicrophoneCallbackAt {
            let age = now.timeIntervalSince(last)
            if age <= 3 {
                lines.append("microphone: listening (live audio callbacks)")
            } else {
                lines.append("microphone: stalled (last callback \(ageText(age)) ago)")
            }
        } else {
            lines.append("microphone: no audio callbacks observed")
        }

        if state.status == "starting", state.requestedSystemAudio == true {
            lines.append("system audio: initializing")
        } else if state.captureSystemAudio {
            lines.append("system audio: listening")
        } else if state.requestedSystemAudio == true {
            let detail = state.systemAudioError ?? "permission or capture unavailable"
            lines.append("system audio: unavailable (\(detail))")
        } else {
            lines.append("system audio: not requested (--mic-only)")
        }
        return lines
    }

    private static func ageText(_ seconds: TimeInterval) -> String {
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds.rounded()))s"
    }
}
