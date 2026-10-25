import Foundation

/// Fetches real thumbnails from Synology Photos for the UI.
///
/// The endpoint was recovered from the web client; `type=item` is the value that
/// works (type=unit returns 404):
///   SYNO.FotoTeam.Thumbnail v2 get id=<item> type=item size=sm|m|xl cache_key=<optional>
public final class ThumbnailClient {
    public enum Size: String { case sm, m, xl }

    private let client: NASClient
    private let cacheRoot: URL
    /// Guards `memory`. Many thumbnail loads run concurrently, and an
    /// unguarded dictionary mutation crashed the app inside `_copyOrMoveAndResize`.
    private var memory: [String: Data] = [:]
    /// Insertion order for a bounded cache. Without a cap, browsing a large
    /// library pins every JPEG it has ever displayed in RAM.
    private var insertionOrder: [String] = []
    private let memoryLimit = 400
    private let lock = NSLock()

    public init(client: NASClient, accountID: UUID) {
        self.client = client
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                           in: .userDomainMask).first!
            .appendingPathComponent("SIA-Lite/thumbs/\(accountID.uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.cacheRoot = base
    }

    /// Cache key includes the server's cache_key so a regenerated preview
    /// invalidates the local copy automatically.
    private func cacheURL(id: Int, size: Size, version: String) -> URL {
        cacheRoot.appendingPathComponent("\(id)_\(size.rawValue)_\(version).jpg")
    }

    /// Single writer for `memory`; evicts oldest entries past `memoryLimit`.
    /// Must stay the only place that mutates the cache.
    private func remember(_ key: String, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        if memory[key] == nil { insertionOrder.append(key) }
        memory[key] = data
        while insertionOrder.count > memoryLimit {
            let oldest = insertionOrder.removeFirst()
            memory.removeValue(forKey: oldest)
        }
    }

    /// Async load used by the UI. Disk reads/writes happen off the cooperative
    /// pool and the network call suspends instead of blocking a thread.
    public func thumbnailAsync(id: Int, cacheKey: String?, size: Size) async -> Data? {
        let version = (cacheKey ?? "v").replacingOccurrences(of: "/", with: "_")
        let key = "\(id)-\(size.rawValue)-\(version)"

        lock.lock()
        if let hit = memory[key] { lock.unlock(); return hit }
        lock.unlock()

        let file = cacheURL(id: id, size: size, version: version)
        let disk = await Task.detached(priority: .utility) {
            try? Data(contentsOf: file)
        }.value
        if let disk, disk.count > 100 {
            remember(key, disk)
            return disk
        }

        var params: [String: String] = [
            "id": String(id),
            "type": "item",
            "size": size.rawValue,
        ]
        if let cacheKey, !cacheKey.isEmpty { params["cache_key"] = cacheKey }
        guard let (data, response) = try? await client.rawAsync(api: "SYNO.FotoTeam.Thumbnail",
                                                                version: "2",
                                                                method: "get",
                                                                params: params,
                                                                rangeHeader: nil),
              response.statusCode == 200, data.count > 100,
              data[0] == 0xFF, data[1] == 0xD8      // must be a real JPEG
        else { return nil }
        remember(key, data)
        await Task.detached(priority: .utility) {
            try? data.write(to: file)
        }.value
        return data
    }

    public func thumbnail(id: Int, cacheKey: String?, size: Size) -> Data? {
        let version = (cacheKey ?? "v").replacingOccurrences(of: "/", with: "_")
        let key = "\(id)-\(size.rawValue)-\(version)"

        lock.lock()
        if let hit = memory[key] { lock.unlock(); return hit }
        lock.unlock()

        let file = cacheURL(id: id, size: size, version: version)
        if let data = try? Data(contentsOf: file), data.count > 100 {
            remember(key, data)
            return data
        }

        var params: [String: String] = [
            "id": String(id),
            "type": "item",
            "size": size.rawValue,
        ]
        if let cacheKey, !cacheKey.isEmpty { params["cache_key"] = cacheKey }
        guard let (data, response) = try? client.raw(api: "SYNO.FotoTeam.Thumbnail",
                                                     version: "2",
                                                     method: "get",
                                                     params: params,
                                                     rangeHeader: nil),
              response.statusCode == 200, data.count > 100,
              data[0] == 0xFF, data[1] == 0xD8      // must be a real JPEG
        else { return nil }
        let raw = data

        remember(key, raw)
        try? raw.write(to: file)
        return raw
    }
}
