import Foundation

/// Persists the user-selectable choices so a restart keeps them.
/// Everything the engine treats as "uncertain" lives here, by design: the app
/// never decides silently on the user's behalf.
public final class SettingsStore {
    public static let shared = SettingsStore()

    private let url: URL

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SIA-Lite", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("settings.json")
    }

    /// Per-account settings file.
    private func url(for key: String) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("settings-\(key).json")
    }

    public func load(key: String) -> EngineOptions {
        guard let data = try? Data(contentsOf: url(for: key)),
              let decoded = try? JSONDecoder().decode(EngineOptions.self, from: data) else {
            return EngineOptions()
        }
        return decoded
    }

    public func save(_ options: EngineOptions, key: String) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(options) {
            try? data.write(to: url(for: key), options: .atomic)
        }
    }

    public func load() -> EngineOptions {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(EngineOptions.self, from: data) else {
            return EngineOptions()
        }
        return decoded
    }

    // MARK: - Connection

    public struct Connection: Codable {
        public var host: String = ""
        public var account: String = ""
        public var keychainService: String = "sia-desktop"
        public var keychainAccount: String = "sia-scan"
        public init() {}
    }

    private var connectionURL: URL {
        url.deletingLastPathComponent().appendingPathComponent("connection.json")
    }

    public func loadConnection() -> Connection {
        guard let data = try? Data(contentsOf: connectionURL),
              let decoded = try? JSONDecoder().decode(Connection.self, from: data) else {
            return Connection()
        }
        return decoded
    }

    public func saveConnection(_ connection: Connection) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(connection) {
            try? data.write(to: connectionURL, options: .atomic)
        }
    }

    public func save(_ options: EngineOptions) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(options) {
            try? data.write(to: url, options: .atomic)
        }
    }
}
