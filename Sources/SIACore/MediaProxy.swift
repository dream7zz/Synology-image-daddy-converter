import Foundation
import Network

/// Minimal loopback HTTP/1.1 server that gives ffmpeg a credential-free URL.
///
/// Why: ffmpeg must read an MP4 whose `moov` sits at the end, which means the
/// tool has to issue its own Range requests. Handing ffmpeg the real DSM URL
/// would put the session cookie and SynoToken on the command line (visible in
/// `ps`). Instead we expose `http://127.0.0.1:<port>/unit/<id>` and inject the
/// credentials here, in-process.
public struct RangeRequest {
    public let start: Int
    /// Inclusive end, or nil for "to the end of file".
    public let end: Int?
}

public struct ProxyResponse {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    public init(status: Int, headers: [String: String], body: Data) {
        self.status = status
        self.headers = headers
        self.body = body
    }
}

public protocol ProxyBackend {
    /// - Parameter path: e.g. "/unit/203641"
    func respond(path: String, range: RangeRequest?) throws -> ProxyResponse
}

public enum ProxyError: Error, CustomStringConvertible {
    case badRequest, notFound, backend(String)
    public var description: String {
        switch self {
        case .badRequest: return "bad request"
        case .notFound: return "not found"
        case .backend(let m): return "backend: \(m)"
        }
    }
}

public final class MediaProxy {
    private let backend: ProxyBackend
    private var listener: NWListener?
    public private(set) var port: UInt16 = 0
    /// Total response bytes handed to the client; used to prove that a remote
    /// decode transfers a few MB instead of the whole file.
    public private(set) var bytesServed: Int = 0
    public private(set) var requestCount: Int = 0
    /// (start, end) of every served range, newest last.
    public private(set) var servedRanges: [(start: Int, end: Int)] = []
    private let queue = DispatchQueue(label: "sia.mediaproxy")

    public init(backend: ProxyBackend) { self.backend = backend }

    public func start() throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params)
        self.listener = l
        let sem = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { state in
            switch state {
            case .ready: sem.signal()
            case .failed, .cancelled: sem.signal()
            default: break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            self?.handle(conn)
        }
        l.start(queue: queue)
        _ = sem.wait(timeout: .now() + 5)
        guard let p = l.port?.rawValue, p != 0 else { throw ProxyError.badRequest }
        port = p
        return p
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        receive(conn, buffer: Data())
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
            var buf = buffer
            if let data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf[..<headerEnd.lowerBound], encoding: .utf8) ?? ""
                self.respond(conn, requestHead: head)
                return
            }
            if isComplete || error != nil || buf.count > 64 * 1024 {
                conn.cancel()
                return
            }
            self.receive(conn, buffer: buf)
        }
    }

    private func parseRange(_ value: String?) -> RangeRequest? {
        guard let value, value.hasPrefix("bytes=") else { return nil }
        let spec = value.dropFirst("bytes=".count)
        let parts = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let start = Int(parts[0]) else { return nil }
        let end = parts[1].isEmpty ? nil : Int(parts[1])
        return RangeRequest(start: start, end: end)
    }

    private func respond(_ conn: NWConnection, requestHead: String) {
        let lines = requestHead.split(separator: "\r\n", omittingEmptySubsequences: false)
        let requestLine = lines.first.map(String.init) ?? ""
        let tokens = requestLine.split(separator: " ")
        guard tokens.count >= 2 else { finish(conn, ProxyResponse(status: 400, headers: [:], body: Data())); return }
        let method = String(tokens[0])
        let path = String(tokens[1])
        guard method == "GET" || method == "HEAD" else {
            finish(conn, ProxyResponse(status: 405, headers: [:], body: Data())); return
        }
        var rangeHeader: String?
        for line in lines.dropFirst() {
            let lower = line.lowercased()
            if lower.hasPrefix("range:") {
                rangeHeader = String(line.dropFirst("range:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        let parsedRange = parseRange(rangeHeader)
        do {
            let response = try backend.respond(path: path, range: parsedRange)
            if let r = parsedRange {
                let end = response.headers["Content-Range"]
                    .flatMap { $0.split(separator: "/").first }
                    .flatMap { $0.split(separator: "-").last }
                    .flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } ?? r.start
                servedRanges.append((r.start, end))
            }
            finish(conn, response)
        } catch {
            finish(conn, ProxyResponse(status: 416, headers: ["Content-Length": "0"], body: Data()))
        }
    }

    private func finish(_ conn: NWConnection, _ response: ProxyResponse) {
        var head = "HTTP/1.1 \(response.status) \(response.status == 206 ? "Partial Content" : "OK")\r\n"
        head += "Accept-Ranges: bytes\r\n"
        head += "Connection: close\r\n"
        for (k, v) in response.headers { head += "\(k): \(v)\r\n" }
        head += "Content-Length: \(response.body.count)\r\n\r\n"
        bytesServed += response.body.count
        requestCount += 1
        var payload = Data(head.utf8)
        payload.append(response.body)
        conn.send(content: payload, completion: .contentProcessed { _ in conn.cancel() })
    }
}

/// Serves a local file with byte-range semantics. Used to prove the remote
/// decode path without any NAS access.
public struct LocalFileBackend: ProxyBackend {
    public let fileURL: URL
    /// Never satisfy an open-ended request with the whole file: a client that
    /// asked for `bytes=0-` would otherwise stream 24 GB. Capping the response
    /// makes the client see a partial body and seek to what it actually needs.
    public let maxSlice: Int
    public init(fileURL: URL, maxSlice: Int = 4 << 20) {
        self.fileURL = fileURL
        self.maxSlice = maxSlice
    }

    public func respond(path: String, range: RangeRequest?) throws -> ProxyResponse {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else { throw ProxyError.notFound }
        defer { try? handle.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        let total = size ?? 0
        let start = max(0, range?.start ?? 0)
        let requestedEnd = range?.end ?? (start + maxSlice - 1)
        let end = min(min(requestedEnd, start + maxSlice - 1), total - 1)
        guard start <= end else { throw ProxyError.badRequest }
        try? handle.seek(toOffset: UInt64(start))
        let body = (try? handle.read(upToCount: end - start + 1)) ?? Data()
        var headers = ["Content-Range": "bytes \(start)-\(end)/\(total)",
                       "Content-Type": "video/mp4"]
        if range == nil { headers["Content-Range"] = "bytes 0-\(total - 1)/\(total)" }
        return ProxyResponse(status: 206, headers: headers, body: body)
    }
}

/// Forwards to DSM, injecting the session cookie + SynoToken that ffmpeg must
/// never see. Caps a single response so a broken client cannot pull 24 GB
/// through the proxy in one request.
public struct NASBackend: ProxyBackend {
    let client: NASClient
    let maxSlice: Int
    public init(client: NASClient, maxSlice: Int = 8 << 20) {
        self.client = client
        self.maxSlice = maxSlice
    }

    public func respond(path: String, range: RangeRequest?) throws -> ProxyResponse {
        guard let unit = Int(path.split(separator: "/").last ?? "") else { throw ProxyError.badRequest }
        let start = max(0, range?.start ?? 0)
        let end = min(range?.end ?? (start + maxSlice - 1), start + maxSlice - 1)
        let (data, resp) = try client.raw(api: "SYNO.FotoTeam.Download",
                                          version: "1",
                                          method: "download",
                                          params: ["item_id": "[\(unit)]"],
                                          rangeHeader: "bytes=\(start)-\(end)")
        var headers = ["Content-Type": "video/mp4"]
        if let cr = resp.value(forHTTPHeaderField: "Content-Range") {
            headers["Content-Range"] = cr
        } else {
            headers["Content-Range"] = "bytes \(start)-\(start + data.count - 1)/\(start + data.count)"
        }
        return ProxyResponse(status: 206, headers: headers, body: data)
    }
}
