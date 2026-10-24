import Foundation

/// The ONLY component allowed to mutate the NAS, and it is inert until a caller
/// explicitly opts in. Design rules, in order of enforcement:
///
/// 1. Statically, exactly one API name is reachable (`allowListedAPI`).
/// 2. Every call must pass `mode == .confirmed`, otherwise it throws.
/// 3. Deletion / move / rename / overwrite of originals are not expressible:
///    no such parameter is ever built here.
/// 4. Callers must obtain a `UploadPlan` from `plan(for:)`, which records the
///    exact files and target before anything is sent, so a dry run and a real
///    run produce the same auditable list.
public enum UploadMode: String, Codable, CaseIterable {
    case disabled
    case planOnly     // build and record the plan, send nothing
    case confirmed    // actually upload (still requires explicit opt-in)

    public var label: String {
        switch self {
        case .disabled: return "关闭"
        case .planOnly: return "仅生成计划"
        case .confirmed: return "确认上传"
        }
    }
}

public struct UploadPlan: Codable {
    public let itemID: Int
    public let api: String
    public let files: [String]
    public let totalBytes: Int
    public let createdAt: Date

    public init(itemID: Int, api: String, files: [String],
                totalBytes: Int, createdAt: Date) {
        self.itemID = itemID
        self.api = api
        self.files = files
        self.totalBytes = totalBytes
        self.createdAt = createdAt
    }
}

public enum WriteGateError: Error, CustomStringConvertible {
    case modeIsNotConfirmed(UploadMode)
    case noThumbnails(Int)
    case notImplementedContract
    case notConfigured
    case incompleteThumbnails(Int)
    case serverRejected(String)
    case apiBlocked(String)
    /// The server keeps the unit in `converting` (usually a truncated source
    /// file it can never finish), so no converted file may be written.
    case conversionStuck

    public var description: String {
        switch self {
        case .modeIsNotConfirmed(let m):
            return "WriteGate 处于「\(m.label)」模式，不会发出任何写请求"
        case .noThumbnails(let id):
            return "任务 \(id) 没有已生成的缩略图"
        case .notImplementedContract:
            return "上传契约尚未确认（等待 B1 捕获结果），WriteGate 拒绝猜测参数"
        case .notConfigured:
            return "WriteGate 未配置 NAS 客户端"
        case .incompleteThumbnails(let id):
            return "任务 \(id) 的三档缩略图不完整"
        case .serverRejected(let detail):
            return "NAS 拒绝了上传: \(detail)"
        case .apiBlocked(let api):
            return "API \(api) 不在白名单内，已拒绝"
        case .conversionStuck:
            return "NAS 侧转换任务卡死（源文件不完整），无法写入缩略图"
        }
    }
}

public final class WriteGate {
    /// The one and only API this component may ever call.
    public static let allowListedAPI = "SYNO.FotoTeam.Upload.ConvertedFile"

    public var mode: UploadMode
    public private(set) var plans: [UploadPlan] = []
    private let client: NASClient?

    public init(mode: UploadMode = .disabled, client: NASClient? = nil) {
        self.mode = mode
        self.client = client
    }

    /// Builds the auditable plan for one finished job.
    public func plan(for job: Job, thumbDir: URL) throws -> UploadPlan {
        // The thumbnailer names outputs `<stem>_<size>.jpg`, and `stem` is not
        // always the original filename (the engine uses "sample"). Match on the
        // size suffix instead of reconstructing the name.
        let entries = (try? FileManager.default.contentsOfDirectory(atPath: thumbDir.path)) ?? []
        var files: [String] = []
        for size in ["xl", "m", "sm"] {
            let candidates = entries.filter { $0.hasSuffix("_\(size).jpg") }.sorted()
            guard let name = candidates.first else {
                throw WriteGateError.noThumbnails(job.id)
            }
            files.append(thumbDir.appendingPathComponent(name).path)
        }
        let bytes = files.reduce(0) { sum, path in
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            return sum + ((attrs?[.size] as? NSNumber)?.intValue ?? 0)
        }
        return UploadPlan(itemID: job.id,
                          api: Self.allowListedAPI,
                          files: files,
                          totalBytes: bytes,
                          createdAt: Date())
    }

    public func upload(_ plan: UploadPlan) throws {
        guard plan.api == Self.allowListedAPI else {
            throw WriteGateError.apiBlocked(plan.api)
        }
        guard mode == .confirmed else {
            throw WriteGateError.modeIsNotConfirmed(mode)
        }
        guard let client else { throw WriteGateError.notConfigured }
        guard plan.files.count == 3 else { throw WriteGateError.incompleteThumbnails(plan.itemID) }

        // Step 1 — create the regenerate task. The upload endpoint rejects a bare
        // browse item id with "unit id not exist"; the task carries its own
        // `unit_id`, which is what the upload must reference.
        // Recovered from the web client: `set_regenerating({item_id: [...]})`.
        let task = try client.call(api: "SYNO.FotoTeam.RegeneratePreview",
                                   version: "1",
                                   method: "set_regenerating",
                                   params: ["item_id": "[\(plan.itemID)]"])
        let list = (task["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
        // Some items (notably MPEG-PS recordings) return an empty list because
        // the server already has a stuck task; the unit id is still published
        // in the item's thumbnail block, and uploading against it works.
        let unitID: Int
        if let fromTask = list.first?["unit_id"] as? Int {
            unitID = fromTask
        } else {
            let item = try client.call(api: "SYNO.FotoTeam.Browse.Item",
                                       version: "7",
                                       method: "get",
                                       params: ["id": "[\(plan.itemID)]",
                                                "additional": #"["thumbnail"]"#])
            let row = (item["data"] as? [String: Any])?["list"] as? [[String: Any]] ?? []
            let thumb = (row.first?["additional"] as? [String: Any])?["thumbnail"] as? [String: Any] ?? [:]
            guard let existing = thumb["unit_id"] as? Int else {
                throw WriteGateError.serverRejected("没有拿到转换任务 unit_id")
            }
            unitID = existing
        }

        // Step 2 — upload the three JPEGs against that task's unit_id.
        func data(_ suffix: String) throws -> Data {
            guard let path = plan.files.first(where: { $0.contains("_\(suffix).jpg") }) else {
                throw WriteGateError.incompleteThumbnails(plan.itemID)
            }
            return try Data(contentsOf: URL(fileURLWithPath: path))
        }
        let upload = ConvertedFileUpload(unitID: unitID,
                                         token: client.token,
                                         xl: try data("xl"),
                                         m: try data("m"),
                                         sm: try data("sm"))
        let response = try client.postMultipart(api: ConvertedFileUpload.api,
                                                version: ConvertedFileUpload.version,
                                                method: ConvertedFileUpload.method,
                                                body: upload.body())
        if let err = response["error"] as? [String: Any], (err["code"] as? Int) == 117 {
            throw WriteGateError.conversionStuck
        }
        guard (response["success"] as? Bool) == true else {
            throw WriteGateError.serverRejected(String(describing: response["error"] ?? "unknown"))
        }
    }
}
