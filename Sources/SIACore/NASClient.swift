import Foundation

public struct NASError: Error, CustomStringConvertible {
    public let code: Int
    public let message: String
    public init(code: Int, message: String) { self.code = code; self.message = message }
    public var description: String { "NAS error \(code): \(message)" }
}

/// Thin DSM client.
///
/// DSM 7.4 Photos requires three things together, each of which was verified
/// against the live NAS during M0:
///  1. login with `session=webui` (Photos/dsm/PhotoStation all return 402)
///  2. the `id` cookie that login sets (passing `sid` as a parameter yields 119)
///  3. the `X-SYNO-TOKEN` header / `SynoToken` parameter
///
/// Cookies are handled by a private cookie storage so the CLI never touches the
/// user's browser cookies.
public final class NASClient {
    public let host: String
    public let account: String
    private let keychainService: String
    private let keychainAccount: String
    /// Used only by the login flow, before the password is in the Keychain.
    private let passwordOverride: String?
    private let session: URLSession
    public private(set) var token: String?
    private var cookies: [String: String] = [:]
    /// Serialises cookie/token bookkeeping; requests run concurrently.
    private let stateLock = NSLock()

    public init(host: String,
                account: String,
                keychainService: String = "sia-desktop",
                keychainAccount: String = "sia-scan") {
        self.host = host
        self.account = account
        self.keychainService = keychainService
        self.keychainAccount = keychainAccount
        self.passwordOverride = nil

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    /// Verifies credentials before they are stored. Nothing is persisted here.
    public init(host: String, account: String, password: String) {
        self.host = host
        self.account = account
        self.keychainService = ""
        self.keychainAccount = ""
        self.passwordOverride = password

        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = HTTPCookieStorage()
        cfg.httpShouldSetCookies = true
        cfg.httpCookieAcceptPolicy = .always
        cfg.timeoutIntervalForRequest = 60
        cfg.timeoutIntervalForResource = 600
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: cfg)
    }

    // MARK: - Credentials

    /// Reads the password from the login Keychain. The value is never logged.
    private func readPassword() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", keychainService,
                       "-a", keychainAccount, "-w"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do { try p.run() } catch {
            throw NASError(code: -10, message: "cannot launch security(1): \(error)")
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw NASError(code: -11,
                           message: "keychain item \(keychainService)/\(keychainAccount) not found")
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        guard let s = String(data: data, encoding: .utf8) else {
            throw NASError(code: -12, message: "keychain value not utf8")
        }
        return s.trimmingCharacters(in: .newlines)
    }

    // MARK: - Transport

    private func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    private func formBody(_ params: [String: String]) -> Data {
        params
            .sorted { $0.key < $1.key }
            .map { "\(escape($0.key))=\(escape($0.value))" }
            .joined(separator: "&")
            .data(using: .utf8) ?? Data()
    }

    private func endpoint() -> URL {
        URL(string: "https://\(host)/webapi/entry.cgi")!
    }

    private func send(_ request: URLRequest,
                      onBytes: ((Int64, Int64) -> Void)? = nil) throws -> (Data, HTTPURLResponse) {
        var req = request
        // Snapshot under the lock: another request may be absorbing Set-Cookie.
        stateLock.lock()
        let cookieHeader = cookies.isEmpty
            ? nil
            : cookies.map { "\($0.key)=\($0.value)" }.joined(separator: "; ")
        stateLock.unlock()
        if let cookieHeader {
            req.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
        }
        let sem = DispatchSemaphore(value: 0)
        var boxed: Result<(Data, HTTPURLResponse), Error>?
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if let err { boxed = .failure(err); return }
            guard let http = resp as? HTTPURLResponse, let data else {
                boxed = .failure(NASError(code: -20, message: "malformed response")); return
            }
            boxed = .success((data, http))
        }
        // One request can carry megabytes; poll the task so the bar moves
        // inside it instead of jumping 0 -> 100.
        var ticker: DispatchSourceTimer?
        if let onBytes {
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
            timer.schedule(deadline: .now() + .milliseconds(120), repeating: .milliseconds(120))
            timer.setEventHandler {
                let received = task.countOfBytesReceived
                let expected = task.countOfBytesExpectedToReceive
                if received > 0, expected > 0 { onBytes(received, expected) }
            }
            timer.resume()
            ticker = timer
        }
        task.resume()
        // A bare `sem.wait()` can block forever if the network stack stalls,
        // which used to freeze an entire batch. Always bound the wait.
        let waited = sem.wait(timeout: .now() + 30)
        ticker?.cancel()
        if waited == .timedOut {
            task.cancel()
            throw NASError(code: -23, message: "request timed out after 90s")
        }
        guard let out = boxed else {
            throw NASError(code: -21, message: "no response")
        }
        switch out {
        case .failure(let e): throw e
        case let .success(v):
            absorbCookies(v.1)
            return v
        }
    }

    /// DSM merges every cookie into a single `Set-Cookie` header value, and the
    /// `expires` attribute itself contains a comma, so a naive split is wrong.
    /// Split only where a comma is followed by `name=`.
    private func absorbCookies(_ http: HTTPURLResponse) {
        stateLock.lock(); defer { stateLock.unlock() }
        for (key, value) in http.allHeaderFields
        where String(describing: key).lowercased() == "set-cookie" {
            let raw = String(describing: value)
            let split = raw.replacingOccurrences(of: #",\s*(?=[A-Za-z0-9_\-]+=)"#,
                                                 with: "\n",
                                                 options: .regularExpression)
            for piece in split.split(separator: "\n") {
                let head = piece.split(separator: ";").first.map(String.init) ?? ""
                let pair = head.split(separator: "=", maxSplits: 1).map(String.init)
                guard pair.count == 2 else { continue }
                let name = pair[0].trimmingCharacters(in: .whitespaces)
                // Only session cookies matter; never keep long-lived tracking values.
                if name == "id" || name == "did" {
                    cookies[name] = pair[1]
                }
            }
        }
    }

    private func decode(_ data: Data, context: String) throws -> [String: Any] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            let head = String(data: data.prefix(120), encoding: .utf8) ?? "<binary>"
            throw NASError(code: -22, message: "\(context): unparsable response: \(head)")
        }
        return obj
    }

    private func checkSuccess(_ obj: [String: Any], context: String) throws -> [String: Any] {
        if (obj["success"] as? Bool) == true { return obj }
        let code = ((obj["error"] as? [String: Any])?["code"] as? Int) ?? -1
        throw NASError(code: code, message: context)
    }

    // MARK: - Public API

    public func login() throws {
        let pw = try passwordOverride ?? readPassword()
        var req = URLRequest(url: endpoint())
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8",
                     forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody([
            "api": "SYNO.API.Auth",
            "version": "6",
            "method": "login",
            "account": account,
            "passwd": pw,
            "session": "webui",
            "format": "cookie",
            "enable_syno_token": "yes",
        ])
        let (data, _) = try send(req)
        let obj = try checkSuccess(try decode(data, context: "login"), context: "login")
        token = (obj["data"] as? [String: Any])?["synotoken"] as? String
        guard token?.isEmpty == false else {
            throw NASError(code: -23, message: "login succeeded but no synotoken")
        }
    }

    /// POSTs one Synology API call and returns the decoded envelope.
    public func call(api: String,
                     version: String = "1",
                     method: String? = nil,
                     params: [String: String] = [:]) throws -> [String: Any] {
        var p = params
        p["api"] = api
        p["version"] = version
        if let method { p["method"] = method }
        if let token { p["SynoToken"] = token }

        var req = URLRequest(url: endpoint())
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded; charset=utf-8",
                     forHTTPHeaderField: "Content-Type")
        if let token { req.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN") }
        req.httpBody = formBody(p)

        if ProcessInfo.processInfo.environment["SIA_DEBUG"] != nil {
            let body = String(data: req.httpBody ?? Data(), encoding: .utf8) ?? ""
            FileHandle.standardError.write(Data("[debug] POST \(api) body: \(body)\n".utf8))
        }

        let (data, _) = try send(req)
        return try checkSuccess(try decode(data, context: api), context: api)
    }

    /// Multipart POST used by the one write endpoint.
    public func postMultipart(api: String, version: String, method: String,
                              body: MultipartBody) throws -> [String: Any] {
        var comps = URLComponents(url: endpoint(), resolvingAgainstBaseURL: false)!
        var items = [URLQueryItem(name: "api", value: api),
                     URLQueryItem(name: "version", value: version),
                     URLQueryItem(name: "method", value: method)]
        if let token { items.append(URLQueryItem(name: "SynoToken", value: token)) }
        comps.queryItems = items

        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue(body.contentType, forHTTPHeaderField: "Content-Type")
        if let token { req.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN") }
        req.httpBody = body.data

        let (data, _) = try send(req)
        return try decode(data, context: api)
    }

    /// Raw byte fetch for media endpoints. Returns whatever the server sends.
    public func raw(api: String, version: String = "1", method: String? = nil,
                    params: [String: String] = [:],
                    rangeHeader: String? = nil,
                    onBytes: ((Int64, Int64) -> Void)? = nil) throws -> (Data, HTTPURLResponse) {
        var p = params
        p["api"] = api
        p["version"] = version
        if let method { p["method"] = method }
        if let token { p["SynoToken"] = token }
        var comps = URLComponents(url: endpoint(), resolvingAgainstBaseURL: false)!
        comps.queryItems = p.map { URLQueryItem(name: $0.key, value: $0.value) }
        var req = URLRequest(url: comps.url!)
        if let token { req.setValue(token, forHTTPHeaderField: "X-SYNO-TOKEN") }
        if let rangeHeader { req.setValue(rangeHeader, forHTTPHeaderField: "Range") }
        return try send(req, onBytes: onBytes)
    }
}

extension NASClient {
    /// Cheap check: does the NAS already serve all three sizes for this item?
    /// One small request, used to avoid decoding/uploading work that a previous
    /// run (or the NAS itself) already finished.
    public func thumbnailReady(itemID: Int) -> Bool? {
        guard let resp = try? call(api: "SYNO.FotoTeam.Browse.Item",
                                   version: "7",
                                   method: "get",
                                   params: ["id": "[\(itemID)]",
                                            "additional": #"["thumbnail"]"#]) else { return nil }
        guard let list = (resp["data"] as? [String: Any])?["list"] as? [[String: Any]],
              let first = list.first,
              let thumb = (first["additional"] as? [String: Any])?["thumbnail"] as? [String: Any]
        else { return nil }
        return ["sm", "m", "xl"].allSatisfy { (thumb[$0] as? String) == "ready" }
    }
}
