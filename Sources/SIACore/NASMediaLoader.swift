import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Streams a NAS item into AVPlayer without a local HTTP server.
///
/// The loopback proxy works for ffmpeg, but AVFoundation rejects a partial
/// answer to `Range: bytes=0-` ("content range mismatch"), so playback uses a
/// resource loader instead: AVFoundation asks for byte ranges, we fetch exactly
/// those ranges from the NAS and hand them back.
public final class NASMediaLoader: NSObject, AVAssetResourceLoaderDelegate {

    public static let scheme = "sia"

    private let client: NASClient
    private let queue = DispatchQueue(label: "sia.media.loader", qos: .userInitiated)
    private var totalCache: [Int: Int] = [:]
    private let statsLock = NSLock()
    private var served = 0
    /// Bytes fetched from the NAS so far (for measuring/telemetry).
    public var bytesServed: Int {
        statsLock.lock(); defer { statsLock.unlock() }
        return served
    }

    public init(client: NASClient) {
        self.client = client
        super.init()
    }

    /// `sia://item/<id>`
    public static func url(for itemID: Int) -> URL {
        URL(string: "\(scheme)://item/\(itemID)")!
    }

    private func itemID(from url: URL) -> Int? {
        Int(url.lastPathComponent)
    }

    /// Total size via a one-byte range request's Content-Range header.
    private func totalSize(itemID: Int) throws -> Int {
        if let cached = totalCache[itemID] { return cached }
        let (_, resp) = try client.raw(api: "SYNO.FotoTeam.Download",
                                       version: "1",
                                       method: "download",
                                       params: ["item_id": "[\(itemID)]"],
                                       rangeHeader: "bytes=0-0")
        if let cr = resp.value(forHTTPHeaderField: "Content-Range"),
           let slash = cr.lastIndex(of: "/"),
           let total = Int(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)) {
            totalCache[itemID] = total
            return total
        }
        throw NSError(domain: "sia.media", code: -1,
                      userInfo: [NSLocalizedDescriptionKey: "无法获取文件大小"])
    }

    private func fetch(itemID: Int, offset: Int, length: Int) throws -> Data {
        let end = offset + length - 1
        let (data, resp) = try client.raw(api: "SYNO.FotoTeam.Download",
                                          version: "1",
                                          method: "download",
                                          params: ["item_id": "[\(itemID)]"],
                                          rangeHeader: "bytes=\(offset)-\(end)")
        statsLock.lock(); served += data.count; statsLock.unlock()
        guard resp.statusCode < 400, !data.isEmpty else {
            throw NSError(domain: "sia.media", code: -2,
                          userInfo: [NSLocalizedDescriptionKey: "读取失败 (HTTP \(resp.statusCode))"])
        }
        // A JSON error can arrive with HTTP 200; treat it as a failure.
        if data.count < 200, data.first == UInt8(ascii: "{") {
            throw NSError(domain: "sia.media", code: -3,
                          userInfo: [NSLocalizedDescriptionKey: "NAS 拒绝了该条目"])
        }
        return data
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               shouldWaitForLoadingOfRequestedResource request: AVAssetResourceLoadingRequest) -> Bool {
        guard let url = request.request.url, let id = itemID(from: url) else { return false }

        if let info = request.contentInformationRequest {
            do {
                let total = try totalSize(itemID: id)
                info.contentLength = Int64(total)
                info.isByteRangeAccessSupported = true
                info.contentType = UTType.mpeg4Movie.identifier
            } catch {
                request.finishLoading(with: error)
                return true
            }
        }

        guard let dataRequest = request.dataRequest else {
            request.finishLoading()
            return true
        }

        let offset = Int(dataRequest.requestedOffset)
        let wanted = dataRequest.requestedLength
        queue.async {
            var cursor = offset
            let end = offset + wanted
            let chunk = 4 << 20
            while cursor < end {
                let want = min(chunk, end - cursor)
                do {
                    let data = try self.fetch(itemID: id, offset: cursor, length: want)
                    if data.isEmpty { break }
                    dataRequest.respond(with: data)
                    cursor += data.count
                    if data.count < want { break }   // reached EOF
                } catch {
                    request.finishLoading(with: error)
                    return
                }
                if request.isCancelled { return }
            }
            request.finishLoading()
        }
        return true
    }

    public func resourceLoader(_ resourceLoader: AVAssetResourceLoader,
                               didCancel loadingRequest: AVAssetResourceLoadingRequest) {
        // The next range request simply starts again; nothing to clean up.
    }
}
