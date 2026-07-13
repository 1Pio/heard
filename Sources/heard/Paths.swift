import Foundation

enum HeardPaths {
    static let root: URL = {
        if let override = ProcessInfo.processInfo.environment["HEARD_HOME"], !override.isEmpty {
            return URL(fileURLWithPath: NSString(string: override).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/heard", isDirectory: true)
    }()

    static let memory = root.appendingPathComponent("memory.jsonl")
    static let state = root.appendingPathComponent("state.json")
    static let health = root.appendingPathComponent("health.json")
    static let log = root.appendingPathComponent("heard.log")

    static func prepare() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: memory.path) {
            FileManager.default.createFile(atPath: memory.path, contents: nil)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: memory.path)
    }
}

struct RuntimeState: Codable {
    var pid: Int32
    var status: String
    var startedAt: Date
    var updatedAt: Date
    var captureSystemAudio: Bool
    var lastError: String?
    var requestedSystemAudio: Bool?
    var systemAudioError: String?

    static func load() -> RuntimeState? {
        guard let data = try? Data(contentsOf: HeardPaths.state) else { return nil }
        return try? JSONDecoder.heard.decode(Self.self, from: data)
    }

    func save() throws {
        let data = try JSONEncoder.heard.encode(self)
        try data.write(to: HeardPaths.state, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: HeardPaths.state.path)
    }

    var isAlive: Bool { pid > 0 && kill(pid, 0) == 0 }
}

extension JSONEncoder {
    static var heard: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}

extension JSONDecoder {
    static var heard: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum ISOTime {
    private static func formatter(fractional: Bool) -> ISO8601DateFormatter {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = fractional
            ? [.withInternetDateTime, .withFractionalSeconds]
            : [.withInternetDateTime]
        return formatter
    }

    static func string(_ date: Date) -> String { formatter(fractional: true).string(from: date) }

    static func parse(_ value: String) -> Date? {
        if let date = formatter(fractional: true).date(from: value) { return date }
        return formatter(fractional: false).date(from: value)
    }
}
