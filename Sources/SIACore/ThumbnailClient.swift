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

    public func thumbnail(id: Int, cacheKey: String?, size: Size) -> Data? {
        let version = (cacheKey ?? "v").replacingOccurrences(of: "/", with: "_")
        let key = "\(id)-\(size.rawValue)-\(version)"

        lock.lock()
        if let hit = memory[key] { lock.unlock(); return hit }
        lock.unlock()

        let file = cacheURL(id: id, size: size, version: version)
        if let data = try? Data(contentsOf: file), data.count > 100 {
            lock.lock(); memory[key] = data; lock.unlock()
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

        lock.lock(); memory[key] = raw; lock.unlock()
        try? raw.write(to: file)
        return raw
    }
}
