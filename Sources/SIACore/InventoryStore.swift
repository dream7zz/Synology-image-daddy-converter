import Foundation

/// Cached result of the last scan, so the window has content the moment it
/// opens instead of waiting for the whole library to be walked again.
public struct Inventory: Codable {
    public var items: [PhotoItem]
    public var folders: [FolderEntry]
    public var scannedAt: Date
    /// Root folders the user actually asked to scan.
    public var scannedRoots: [FolderEntry]?

    public init(items: [PhotoItem], folders: [FolderEntry], scannedAt: Date = Date(),
                scannedRoots: [FolderEntry]? = nil) {
        self.items = items
        self.folders = folders
        self.scannedAt = scannedAt
        self.scannedRoots = scannedRoots
    }
}

public enum InventoryStore {
    private static func url(key: String) -> URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SIA-Lite", isDirectory: true)
        return dir.appendingPathComponent("inventory-\(key).json")
    }

    public static func load(key: String) -> Inventory? {
        guard let data = try? Data(contentsOf: url(key: key)),
              let inv = try? JSONDecoder().decode(Inventory.self, from: data) else { return nil }
        return inv
    }

    public static func save(_ inventory: Inventory, key: String) {
        // Keep the previous file around: a partial scan must not be able to
        // destroy a good inventory.
        if let existing = Optional(url(key: key)), FileManager.default.fileExists(atPath: existing.path) {
            let backup = existing.appendingPathExtension("bak")
            try? FileManager.default.removeItem(at: backup)
            try? FileManager.default.copyItem(at: existing, to: backup)
        }
        let dir = url(key: key).deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let enc = JSONEncoder()
        if let data = try? enc.encode(inventory) {
            try? data.write(to: url(key: key), options: .atomic)
        }
    }
}
