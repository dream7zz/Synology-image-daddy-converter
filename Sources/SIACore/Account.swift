import Foundation

/// One NAS account. Passwords never live here — only a Keychain service name.
public struct Account: Codable, Identifiable, Equatable {
    public var id: UUID
    public var displayName: String
    public var host: String
    public var username: String
    public var lastUsedAt: Date

    public var keychainService: String { "sia-\(id.uuidString)" }

    public init(id: UUID = UUID(), displayName: String, host: String,
                username: String, lastUsedAt: Date = Date()) {
        self.id = id
        self.displayName = displayName
        self.host = host
        self.username = username
        self.lastUsedAt = lastUsedAt
    }

    /// Tolerates both a numeric timestamp and an ISO string so a hand-edited
    /// accounts.json never makes the whole list disappear.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        displayName = try c.decode(String.self, forKey: .displayName)
        host = try c.decode(String.self, forKey: .host)
        username = try c.decode(String.self, forKey: .username)
        if let t = try? c.decode(Date.self, forKey: .lastUsedAt) {
            lastUsedAt = t
        } else if let s = try? c.decode(String.self, forKey: .lastUsedAt),
                  let d = ISO8601DateFormatter().date(from: s) {
            lastUsedAt = d
        } else {
            lastUsedAt = Date()
        }
    }

    /// Two-letter monogram for the sidebar avatar.
    public var initials: String {
        let base = displayName.isEmpty ? username : displayName
        let letters = base.prefix(2)
        return String(letters).uppercased()
    }

    /// Stable hue per account so the avatar colour is recognisable at a glance.
    public var hue: Double {
        let sum = id.uuidString.unicodeScalars.reduce(0) { $0 + Int($1.value) }
        return Double(sum % 360) / 360.0
    }
}

/// Persists the account list and talks to the login Keychain.
public final class AccountsStore {
    public static let shared = AccountsStore()

    private let url: URL
    public private(set) var accounts: [Account] = []

    public init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first!
            .appendingPathComponent("SIA-Lite", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("accounts.json")
        self.accounts = (try? Data(contentsOf: url))
            .flatMap { try? JSONDecoder().decode([Account].self, from: $0) } ?? []
    }

    public func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(accounts) {
            try? data.write(to: url, options: .atomic)
        }
    }

    public func upsert(_ account: Account) {
        if let i = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[i] = account
        } else {
            accounts.append(account)
        }
        save()
    }

    public func remove(_ account: Account) {
        accounts.removeAll { $0.id == account.id }
        deletePassword(for: account)
        save()
    }

    // MARK: Keychain

    /// Stores the password for an account. Uses `security(1)` so the value never
    /// passes through our own logs or argv of a long-lived process.
    @discardableResult
    public func storePassword(_ password: String, for account: Account) -> Bool {
        let del = Process()
        del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        del.arguments = ["delete-generic-password", "-s", account.keychainService]
        del.standardError = Pipe(); del.standardOutput = Pipe()
        try? del.run(); del.waitUntilExit()

        let add = Process()
        add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        add.arguments = ["add-generic-password",
                         "-s", account.keychainService,
                         "-a", account.username,
                         "-w", password,
                         "-U"]
        add.standardError = Pipe(); add.standardOutput = Pipe()
        do { try add.run() } catch { return false }
        add.waitUntilExit()
        return add.terminationStatus == 0
    }

    public func hasPassword(for account: Account) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", account.keychainService, "-w"]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }

    public func deletePassword(for account: Account) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["delete-generic-password", "-s", account.keychainService]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
    }

    public func client(for account: Account) -> NASClient {
        NASClient(host: account.host, account: account.username,
                  keychainService: account.keychainService,
                  keychainAccount: account.username)
    }
}
