import Foundation

public struct FetchedSample {
    public let data: Data
    public let totalBytes: Int?
    public let contentType: String?
}

public enum FetchError: Error, CustomStringConvertible {
    case permissionDenied(code: Int)
    case http(Int)
    case empty
    case cancelled
    case timeout

    public var description: String {
        switch self {
        case .permissionDenied(let code):
            return "NAS 拒绝读取 (error \(code))：可能正在重建索引/繁忙，或账号缺少下载权限"
        case .http(let code): return "HTTP \(code)"
        case .empty: return "服务器返回空内容"
        case .timeout: return "读取超时（已重试 3 次）"
        case .cancelled: return "已取消"
        }
    }
}

/// Where the bytes come from. Two implementations: the NAS and a local file
/// (the latter exists so the whole pipeline can be exercised without touching
/// a real library — useful for tests and for the dry-run demo).
public protocol ByteSource {
    func fetch(job: Job,
               budget: Int,
               onProgress: @escaping (Double) -> Void,
               shouldPause: () -> Bool) throws -> FetchedSample
    /// Whether a prefix-only read can be decoded (MP4 index at the front).
    /// `nil` means unknown.
    func canPrefixRead(job: Job) -> Bool?
}

public extension ByteSource {
    func canPrefixRead(job: Job) -> Bool? { nil }
}

public enum Fetcher {
    /// Chunked read so progress is smooth and pause can land between chunks.
    /// For a prefix read of a 24 GB clip this is a handful of requests.
    public static func chunked(client: NASClient,
                               unitId: Int,
                               cacheKey: String?,
                               budget: Int,
                               deadline: TimeInterval = 300,
                               onTick: ((Double) -> Void)? = nil,
                               chunkHandler: (Data, Double) -> Bool) throws -> FetchedSample {
        let started = Date()
        var collected = Data()
        var offset = 0
        var total: Int? = nil
        var contentType: String? = nil
        // Each chunk is a separate HTTPS round-trip, and the round-trip cost
        // dominates for small files: 2.6 MB in 20 requests took 9 s, in 2
        // requests ~1 s. Keep chunks large, ticks still land every few MB.
        let chunk = max(4 << 20, budget / 8)

        var refusalAttempts = 0
        while collected.count < budget {
            let end = min(offset + chunk - 1, budget - 1)
            var params: [String: String] = ["item_id": "[\(unitId)]"]
            if let cacheKey { params["cache_key"] = cacheKey }
            // A single stalled request used to hang the whole batch. Retry a
            // few times, and give up once the per-file deadline passes.
            var attempt = 0
            var data = Data()
            var resp: HTTPURLResponse
            while true {
                if Date().timeIntervalSince(started) > deadline { throw FetchError.timeout }
                do {
                    (data, resp) = try client.raw(api: "SYNO.FotoTeam.Download",
                                                  version: "1",
                                                  method: "download",
                                                  params: params,
                                                  rangeHeader: "bytes=\(offset)-\(end)",
                                                  onBytes: { received, expected in
                        // Report inside the request, not only per chunk.
                        let base = Double(collected.count) + Double(received)
                        onTick?(min(0.999, base / Double(max(budget, 1))))
                    })
                    break
                } catch {
                    attempt += 1
                    if attempt >= 3 || Date().timeIntervalSince(started) > deadline {
                        throw FetchError.timeout
                    }
                    Thread.sleep(forTimeInterval: Double(attempt) * 1.5)
                }
            }

            // Refusals arrive as a tiny JSON body with HTTP 200. The server
            // also answers this way while it is re-indexing or rate limiting,
            // so retry with backoff before calling it a permission problem —
            // otherwise a busy NAS looks like a revoked account.
            if data.count < 200,
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               (obj["success"] as? Bool) != true {
                let code = ((obj["error"] as? [String: Any])?["code"] as? Int) ?? -1
                refusalAttempts += 1
                if refusalAttempts < 4, Date().timeIntervalSince(started) < deadline {
                    Thread.sleep(forTimeInterval: Double(refusalAttempts) * 2.0)
                    continue
                }
                throw FetchError.permissionDenied(code: code)
            }
            refusalAttempts = 0
            guard resp.statusCode < 400 else { throw FetchError.http(resp.statusCode) }
            guard !data.isEmpty else { throw FetchError.empty }

            if total == nil, let cr = resp.value(forHTTPHeaderField: "Content-Range"),
               let slash = cr.lastIndex(of: "/") {
                total = Int(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces))
            }
            if contentType == nil { contentType = resp.value(forHTTPHeaderField: "Content-Type") }

            collected.append(data)
            offset += data.count
            let denom = Double(min(budget, total ?? budget))
            let fraction = denom > 0 ? min(1.0, Double(collected.count) / denom) : 0
            if chunkHandler(collected, fraction) == false { throw FetchError.cancelled }
            if data.count < chunk { break }     // server returned the tail
        }
        return FetchedSample(data: collected, totalBytes: total, contentType: contentType)
    }
}

/// NAS-backed source used by the real engine.
public struct NASByteSource: ByteSource {
    let client: NASClient
    public init(client: NASClient) { self.client = client }

    public func canPrefixRead(job: Job) -> Bool? {
        Fetcher.hasMoovInHead(client: client, unitId: job.id, cacheKey: nil)
    }

    public func fetch(job: Job, budget: Int,
                      onProgress: @escaping (Double) -> Void,
                      shouldPause: () -> Bool) throws -> FetchedSample {
        try Fetcher.chunked(client: client,
                            unitId: job.id,
                            cacheKey: nil,
                            budget: budget,
                            onTick: ProcessInfo.processInfo.environment["SIA_NO_TICK"] == "1" ? nil : onProgress) { _, fraction in
            while shouldPause() { Thread.sleep(forTimeInterval: 0.1) }
            onProgress(fraction)
            return true
        }
    }
}

/// Local-file source: same code path, no NAS. Used by `siactl simulate`.
public struct LocalFileSource: ByteSource {
    public func canPrefixRead(job: Job) -> Bool? { true }
    let url: URL
    /// Artificial delay per chunk so progress is observable.
    let chunkDelay: TimeInterval
    public init(url: URL, chunkDelay: TimeInterval = 0.05) {
        self.url = url
        self.chunkDelay = chunkDelay
    }

    public func fetch(job: Job, budget: Int,
                      onProgress: @escaping (Double) -> Void,
                      shouldPause: () -> Bool) throws -> FetchedSample {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw FetchError.empty }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let limit = min(budget, size ?? budget)
        let chunk = max(128 << 10, limit / 24)
        var collected = Data()
        while collected.count < limit {
            while shouldPause() { Thread.sleep(forTimeInterval: 0.1) }
            let n = min(chunk, limit - collected.count)
            guard let piece = try? handle.read(upToCount: n), !piece.isEmpty else { break }
            collected.append(piece)
            Thread.sleep(forTimeInterval: chunkDelay)
            onProgress(min(1.0, Double(collected.count) / Double(limit)))
        }
        guard !collected.isEmpty else { throw FetchError.empty }
        return FetchedSample(data: collected, totalBytes: size, contentType: "video/mp4")
    }
}

extension Fetcher {
    /// MP4 puts its index (`moov`) either at the front (faststart) or at the end.
    /// A prefix-only read can only decode the former, so we check before
    /// spending bandwidth. Returns nil when the answer is inconclusive.
    public static func hasMoovInHead(client: NASClient,
                                     unitId: Int,
                                     cacheKey: String?,
                                     probeBytes: Int = 96 << 10) -> Bool? {
        var params: [String: String] = ["item_id": "[\(unitId)]"]
        if let cacheKey { params["cache_key"] = cacheKey }
        guard let (data, resp) = try? client.raw(api: "SYNO.FotoTeam.Download",
                                                 version: "1",
                                                 method: "download",
                                                 params: params,
                                                 rangeHeader: "bytes=0-\(probeBytes - 1)"),
              resp.statusCode < 400, data.count > 64, data.prefix(4) != Data([0x7B, 0x22, 0x65, 0x72]) // not JSON
        else { return nil }
        return data.range(of: Data("moov".utf8)) != nil
    }
}

/// AVFoundation only opens MP4/MOV; mislabelled MPEG-PS files make it wait for
/// its full timeout before failing, so the container is sniffed up front.
public enum ContainerSniffer {
    public static func sniffMP4(client: NASClient, unitId: Int) -> Bool {
        guard let sample = try? Fetcher.chunked(client: client, unitId: unitId,
                                                cacheKey: nil, budget: 64 * 1024,
                                                deadline: 30, chunkHandler: { _, _ in true }),
              sample.data.count >= 12 else { return false }
        let bytes = [UInt8](sample.data.prefix(12))
        return bytes[4] == 0x66 && bytes[5] == 0x74 && bytes[6] == 0x79 && bytes[7] == 0x70
    }
}
