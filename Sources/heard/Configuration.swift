import Foundation

struct HeardConfiguration: Decodable, Equatable {
    private enum CodingKeys: String, CodingKey { case excludedApps }

    var excludedApps: [String] = []

    init(excludedApps: [String] = []) {
        self.excludedApps = excludedApps
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        excludedApps = try container.decodeIfPresent([String].self, forKey: .excludedApps) ?? []
    }

    static func load(from url: URL = HeardPaths.config) throws -> Self {
        guard FileManager.default.fileExists(atPath: url.path) else { return Self() }
        do {
            return try decode(Data(contentsOf: url))
        } catch let error as HeardError {
            throw error
        } catch {
            throw HeardError("Could not read config at \(url.path): \(error.localizedDescription)")
        }
    }

    static func decode(_ data: Data) throws -> Self {
        let configuration = try JSONDecoder().decode(Self.self, from: data)
        return try Self(excludedApps: normalize(configuration.excludedApps))
    }

    static func merged(configured: [String], commandLine: [String]) throws -> [String] {
        try normalize(configured + commandLine)
    }

    private static func normalize(_ values: [String]) throws -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for rawValue in values {
            let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else {
                throw HeardError("Excluded app bundle identifiers cannot be empty.")
            }
            let validCharacters = value.range(
                of: #"^[A-Za-z0-9][A-Za-z0-9.-]*[A-Za-z0-9]$"#,
                options: .regularExpression
            ) != nil
            guard value.contains("."), validCharacters else {
                throw HeardError("'\(value)' is not an app bundle identifier. Use a value such as com.apple.Music.")
            }
            let key = value.lowercased()
            if seen.insert(key).inserted { result.append(value) }
        }
        return result
    }
}
