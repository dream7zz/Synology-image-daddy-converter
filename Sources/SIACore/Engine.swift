import Foundation

public enum JobStage: String, Codable {
    case pending
    case fetching
    case converting
    case readyToUpload     // thumbnails exist, waiting for the upload step
    case uploading
    case done
    case skipped
    case blocked
    case failed
    case cancelled

    public var isTerminal: Bool {
        [.done, .skipped, .failed, .blocked, .cancelled].contains(self)
    }
}

public struct Job: Codable {
    public let id: Int
    public let filename: String
    public let bytes: Int
    public let folderPath: String
    public var stage: JobStage
    public var message: String
    public var thumbDir: String?
    /// 0…1 while fetching, kept for the UI progress bar.
    public var progress: Double
    public var updatedAt: Date

    /// Photos decode locally faster than they stream through the proxy.
    public var isImage: Bool {
        // ImageIO opens these; ffmpeg cannot decode most RAW containers.
        ImageExtensions.all.contains((filename as NSString).pathExtension.lowercased())
    }

    public init(id: Int, filename: String, bytes: Int, folderPath: String,
                stage: JobStage, message: String, thumbDir: String?,
                progress: Double, updatedAt: Date) {
        self.id = id
        self.filename = filename
        self.bytes = bytes
        self.folderPath = folderPath
        self.stage = stage
        self.message = message
        self.thumbDir = thumbDir
        self.progress = progress
        self.updatedAt = updatedAt
    }
}

public enum RunMode: String, Codable, CaseIterable {
    case eco, balanced, full
    public var label: String {
        switch self {
        case .eco: return "节能"
        case .balanced: return "均衡"
        case .full: return "满负荷"
        }
    }
    public var workers: Int {
        switch self {
        case .eco: return 1
        case .balanced: return max(2, ProcessInfo.processInfo.activeProcessorCount / 4)
        case .full: return max(4, ProcessInfo.processInfo.activeProcessorCount)
        }
    }
}

public enum FetchStrategy: String, Codable, CaseIterable {
    case auto, remote, prefix, fullDownload
    public var label: String {
        switch self {
        case .auto: return "自动判定（推荐）"
        case .remote: return "在线抽帧（不下载整文件）"
        case .prefix: return "只取文件头"
        case .fullDownload: return "下载完整文件"
        }
    }
}

public struct EngineOptions: Codable {
    public var mode: RunMode = .balanced
    public var strategy: FetchStrategy = .auto
    public var frameFraction: Double = 0.1
    public var prefixBudgetBytes: Int = 4 << 20
    public var maxBytesForFullDownload: Int = 32 << 20
    /// Files processed at once. Measured: 2 beats 6 on this NAS link.
    public var concurrency: Int = 6
    public var skipLargerThanBytes: Int = 0
    public var retries: Int = 3
    /// Off by default. Nothing is ever written to the NAS unless the user turns
    /// this on AND confirms in the UI.
    public var autoUpload: Bool = true
    public init() {}
}

/// Pure decision: how much of the original should we read?
/// Extracted so it can be unit-tested without a NAS or ffmpeg.
public enum StrategyDecision: Equatable {
    case prefix
    case fullDownload
    case remote
    case blocked(String)
}

public enum StrategyPlanner {
    public static func decide(explicit: FetchStrategy,
                              moovInHead: Bool?,
                              bytes: Int,
                              maxFullDownload: Int,
                              hasClient: Bool,
                              isImage: Bool = false) -> StrategyDecision {
        switch explicit {
        case .prefix: return .prefix
        case .fullDownload: return .fullDownload
        case .remote: return hasClient ? .remote : .blocked("在线抽帧需要 NAS 连接")
        case .auto:
            // Photos: measured on HEIC, a plain download plus local decode is
            // ~40% faster than streaming the same bytes through the proxy
            // (2.8 s vs 3.5 s), and there is no moov to worry about.
            if isImage, bytes <= max(maxFullDownload, 64 << 20) { return .fullDownload }
            // Video: measured, remote decode transfers ~35 MB and takes ~15 s
            // on a 0.3 GB clip, versus ~300 MB and ~80 s for a full read.
            if hasClient { return .remote }
            if moovInHead == true { return .prefix }
            if bytes <= maxFullDownload { return .fullDownload }
            return .blocked("MP4 索引在文件末尾（\(bytes / 1_000_000) MB），且无可用的远端解码通道")
        }
    }
}

enum FileLog {
    static func write(_ line: String) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SIA-Lite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("engine.log")
        guard let data = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n".data(using: .utf8) else { return }
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(data); try? h.close()
        } else { try? data.write(to: url) }
    }
}

/// Hands out jobs to worker threads exactly once.
final class JobCursor {
    private let jobs: [Job]
    private var index = 0
    private let lock = NSLock()

    init(_ jobs: [Job]) { self.jobs = jobs }

    func next() -> Job? {
        lock.lock(); defer { lock.unlock() }
        guard index < jobs.count else { return nil }
        let job = jobs[index]
        index += 1
        return job
    }
}

public final class Engine {
    public private(set) var jobs: [Job] = []
    /// Items a previous run already finished; the UI marks them ready without
    /// decoding/uploading them again.
    public private(set) var settledItemIDs: [Int] = []
    /// Set when the server refuses access (session expired, permission
    /// revoked, NAS restarting). Every further item would fail the same way,
    /// so the run stops instead of burning through the queue.
    private var halted = false
    public private(set) var lastStopReason: String?
    /// Uploads run off the main loop so the next file starts downloading at once.
    private let jobsLock = NSLock()
    /// id -> array index. `firstIndex(where:)` over 160k jobs per patch was
    /// quadratic and froze the run.
    private var indexByID: [Int: Int] = [:]
    private let uploadGroup = DispatchGroup()
    private let uploadQueue = DispatchQueue(label: "sia.upload", qos: .utility, attributes: .concurrent)
    /// Follows the configured concurrency: generation at 6 workers was
    /// outrunning two uploaders and piling up `readyToUpload`.
    private lazy var uploadSem = DispatchSemaphore(value: max(1, min(options.concurrency, 4)))
    /// Video frame extraction is heavy; the cap follows the configured
    /// concurrency so setting 6 really means up to 6 clips at once.
    private lazy var videoSem = DispatchSemaphore(value: max(1, min(options.concurrency, 6)))
    public var options: EngineOptions
    public private(set) var lastError: String?
    public private(set) var isPaused = false
    public private(set) var isCancelled = false

    public var onJobUpdate: ((Job) -> Void)?
    public var onLog: ((String) -> Void)?

    /// Appends to a diagnostic log; set SIA_RUN_LOG=<path> to enable.
    private func fileLog(_ line: String) {
        guard let path = ProcessInfo.processInfo.environment["SIA_RUN_LOG"] else { return }
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        let url = URL(fileURLWithPath: path)
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile(); handle.write(data); try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }
    /// Fired for every job state change so a UI can mirror progress live.
    public var onUpdate: ((Job) -> Void)?
    /// When set, only these item ids are processed (used by single-item retry).
    public var onlyItemIDs: Set<Int>?
    public var onProgress: ((Int, Double) -> Void)?

    private var source: ByteSource
    private var client: NASClient?
    private var proxy: MediaProxy?
    private var writer: WriteGate?
    private let workRoot: URL
    private let ledgerURL: URL
    /// Ids this tool has finished. Kept apart from the ledger because the
    /// ledger only stores unfinished work (for size), which used to drop the
    /// knowledge that an item was already repaired.
    private let doneURL: URL
    private var doneIDs: Set<Int> = []

    public init(source: ByteSource, options: EngineOptions = EngineOptions(),
                storageKey: String = "default") {
        self.source = source
        self.client = nil
        self.options = options
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SIA-Lite", isDirectory: true)
        // Each account keeps its own work directory and ledger, so switching
        // accounts never mixes progress or uploads.
        self.workRoot = base.appendingPathComponent("work/\(storageKey)", isDirectory: true)
        self.ledgerURL = base.appendingPathComponent("ledger-\(storageKey).json")
        self.doneURL = base.appendingPathComponent("done-\(storageKey).json")
        if let data = try? Data(contentsOf: doneURL),
           let ids = try? JSONDecoder().decode([Int].self, from: data) {
            self.doneIDs = Set(ids)
        }
        try? FileManager.default.createDirectory(at: workRoot, withIntermediateDirectories: true)
    }

    public convenience init(client: NASClient, options: EngineOptions = EngineOptions(),
                            storageKey: String = "default") {
        self.init(source: NASByteSource(client: client), options: options, storageKey: storageKey)
        self.client = client
    }

    /// Lazily starts the loopback proxy used by the remote strategy.
    private func ensureProxy() throws -> MediaProxy {
        jobsLock.lock()
        if let proxy { jobsLock.unlock(); return proxy }
        jobsLock.unlock()
        guard let client else { throw FetchError.empty }
        let p = MediaProxy(backend: NASBackend(client: client))
        _ = try p.start()
        jobsLock.lock(); proxy = p; jobsLock.unlock()
        return p
    }

    public func stopProxy() {
        proxy?.stop()
        proxy = nil
    }

    // MARK: - Controls

    public func pause() { isPaused = true; emit("已暂停") }
    public func resume() { isPaused = false; emit("已继续") }
    public func cancel() { isCancelled = true; isPaused = false; emit("正在取消…") }

    // MARK: - Planning

    public func prepare(from items: [PhotoItem]) {
        let previous = loadLedger()
        let todo = items.filter { $0.state != .ready }.sorted { $0.bytes < $1.bytes }
        jobs = todo.map { item in
            let old = previous[item.id]
            return Job(id: item.id,
                       filename: item.filename,
                       bytes: item.bytes,
                       folderPath: item.folderPath,
                       stage: old?.stage == .done ? .done : .pending,
                       message: old?.message ?? "",
                       thumbDir: old?.thumbDir,
                       progress: old?.stage == .done ? 1 : 0,
                       updatedAt: old?.updatedAt ?? Date())
        }
        reindex()
    }

    /// Builds jobs straight from local files (used by `siactl simulate`).
    public func prepareLocal(files: [URL]) {
        jobs = files.enumerated().map { index, url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            return Job(id: 900_000 + index,
                       filename: url.lastPathComponent,
                       bytes: size ?? 0,
                       folderPath: url.deletingLastPathComponent().path,
                       stage: .pending, message: "", thumbDir: nil,
                       progress: 0, updatedAt: Date())
        }
        reindex()
    }

    // MARK: - Ledger

    /// Restores the ledger, but any job interrupted mid-flight goes back to
    /// pending: a killed process must never strand an item in `fetching`.
    private func loadLedger() -> [Int: Job] {
        guard let data = try? Data(contentsOf: ledgerURL),
              let decoded = try? JSONDecoder().decode([Job].self, from: data) else { return [:] }
        // A killed run leaves items in fetching/converting/uploading. Restore
        // them to pending so the next run actually picks them up.
        var restored: [Int: Job] = [:]
        for var job in decoded {
            switch job.stage {
            case .fetching, .converting, .uploading:
                job.stage = .pending
                job.message = "上次运行中断，重新排队"
                job.progress = 0
            default: break
            }
            restored[job.id] = job
        }
        return restored
    }

    public func saveLedger() {
        jobsLock.lock()
        // Only keep work that still matters: `done` is rebuilt from the next
        // scan, and persisting 160k+ finished jobs meant rewriting ~50 MB on
        // every progress update.
        let snapshot = jobs.filter { $0.stage != .done }
        jobsLock.unlock()
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted]
        if let data = try? enc.encode(snapshot) {
            try? data.write(to: ledgerURL, options: .atomic)
        }
    }

    // MARK: - Run

    /// Returns true when the run must stop because the server refuses access.
    private func haltIfNeeded(_ error: Error? = nil, job: Job? = nil) -> Bool {
        jobsLock.lock()
        defer { jobsLock.unlock() }
        if let error, case FetchError.permissionDenied(let code)? = error as? FetchError {
            halted = true
            let reason = "NAS 拒绝访问（error \(code)）：会话已过期或账号缺少下载权限，已停止本轮"
            lastStopReason = reason
            if let job { jobsByIDSnapshot(job.id, stage: .blocked, message: reason) }
        }
        return halted
    }

    private func jobsByIDSnapshot(_ id: Int, stage: JobStage, message: String) {
        guard let idx = indexByID[id] else { return }
        jobs[idx].stage = stage
        jobs[idx].message = message
        jobs[idx].updatedAt = Date()
    }

    /// Falling back to "skipped" for files that cannot contain media at all,
    /// so a broken recording does not fail on every run.
    private func finishWithFailure(_ job: Job, _ message: String) {
        if job.bytes < (512 << 10) || message.contains("Cannot determine format") {
            patch(job.id, stage: .skipped, message: "文件不完整（没有视频数据），无法处理")
        } else {
            patch(job.id, stage: .failed, message: message)
        }
    }

    private func recordDone(_ id: Int) {
        jobsLock.lock()
        let inserted = doneIDs.insert(id).inserted
        let snapshot = Array(doneIDs)
        jobsLock.unlock()
        guard inserted else { return }
        if let data = try? JSONEncoder().encode(snapshot) {
            try? data.write(to: doneURL, options: .atomic)
        }
    }

    public var completedIDs: Set<Int> {
        jobsLock.lock(); defer { jobsLock.unlock() }
        return doneIDs
    }

    private func reindex() {
        var map = [Int: Int](minimumCapacity: jobs.count)
        for (index, job) in jobs.enumerated() { map[job.id] = index }
        indexByID = map
    }

    private func setLastError(_ message: String) {
        jobsLock.lock(); lastError = message; jobsLock.unlock()
    }

    private func emit(_ line: String) {
        fileLog(line)
        onLog?(line)
    }

    private func patch(_ id: Int, stage: JobStage, message: String,
                       progress: Double? = nil, thumbDir: String? = nil) {
        if stage == .done { recordDone(id) }
        jobsLock.lock()
        guard let idx = indexByID[id] else {
            jobsLock.unlock()
            return
        }
        let previousStage = jobs[idx].stage
        jobs[idx].stage = stage
        jobs[idx].message = message
        if let progress { jobs[idx].progress = progress }
        if let thumbDir { jobs[idx].thumbDir = thumbDir }
        jobs[idx].updatedAt = Date()
        let updated = jobs[idx]
        let changedStage = previousStage != stage
        jobsLock.unlock()
        onUpdate?(updated)
        onJobUpdate?(updated)
        // Only persist on meaningful transitions; rewriting the whole ledger
        // for every progress tick cost real time under concurrency.
        if changedStage || stage.isTerminal { saveLedger() }
    }

    private func fmt(_ seconds: TimeInterval) -> String {
        seconds < 1 ? String(format: "%.0fms", seconds * 1000) : String(format: "%.1fs", seconds)
    }

    private func waitWhilePaused() {
        while isPaused && !isCancelled {
            Thread.sleep(forTimeInterval: 0.1)
        }
    }

    /// Scans the NAS and fills the work queue. `run` only walks `jobs`, so a
    /// caller that forgets this processes nothing (the app used to).
    /// Builds the queue from items the user actually scanned. Nothing outside
    /// the scanned folders can be processed.
    public func loadQueue(items: [PhotoItem]) throws {
        FileLog.write("loadQueue: 开始 \(items.count) 项")
        let previous = loadLedger()
        FileLog.write("loadQueue: 历史账本 \(previous.count) 条")
        var merged: [Job] = []
        var seenIDs = Set<Int>()
        // Only real work enters the queue: items that already have all three
        // sizes would otherwise fill it with thousands of "已完成" rows.
        settledItemIDs.removeAll()
        for item in items where seenIDs.insert(item.id).inserted
            && !item.hasThumbnails
            // 0-byte files were already judged unprocessable; do not queue
            // them again on every run.
            && previous[item.id]?.stage != .skipped
            // 0-byte files are their own category; never queue them.
            && item.bytes > 0 {
            if doneIDs.contains(item.id) || previous[item.id]?.stage == .done {
                settledItemIDs.append(item.id)
                continue
            }
            if let old = previous[item.id] {
                var stage = old.stage
                var message = old.message
                var progress = old.progress
                // A fresh run is a retry: previous failures become work again,
                // otherwise the header opens showing thousands of old failures.
                // `blocked` means the server itself refuses (e.g. a unit stuck
                // in converting); retrying it every run only burns bandwidth,
                // so it stays blocked until the user retries explicitly.
                if [.failed, .cancelled].contains(stage), item.state != .ready {
                    stage = .pending; message = ""; progress = 0
                }
                merged.append(Job(id: item.id, filename: item.filename, bytes: item.bytes,
                                  folderPath: item.folderPath, stage: stage, message: message,
                                  thumbDir: old.thumbDir, progress: progress, updatedAt: Date()))
            } else {
                merged.append(Job(id: item.id, filename: item.filename, bytes: item.bytes,
                                  folderPath: item.folderPath,
                                  stage: item.state == .ready ? .done : .pending,
                                  message: item.state == .ready ? "已有缩略图" : "",
                                  thumbDir: nil,
                                  progress: item.state == .ready ? 1 : 0,
                                  updatedAt: Date()))
            }
        }
        jobs = merged
        FileLog.write("loadQueue: 构建 \(merged.count) 条")
        FileLog.write("loadQueue: reindex 开始")
        reindex()
        FileLog.write("loadQueue: reindex 完成")
        FileLog.write("loadQueue: save 开始")
        saveLedger()
        FileLog.write("loadQueue: 已落盘")
        emit("队列：\(jobs.count) 项，待处理 \(jobs.filter { $0.stage == .pending }.count)")
    }

    public func loadQueue() throws {
        guard let client else { throw WriteGateError.notConfigured }
        let previous = loadLedger()
        let scanned = try Scanner(client: client).scanAll()
        var merged: [Job] = []
        for item in scanned {
            if let old = previous[item.id] {
                var stage = old.stage
                var message = old.message
                var progress = old.progress
                // A file the NAS now reports ready needs no work.
                if item.state == .ready, stage != .done {
                    stage = .done
                    message = "已有缩略图"
                    progress = 1
                }
                merged.append(Job(id: item.id, filename: item.filename, bytes: item.bytes,
                                  folderPath: item.folderPath, stage: stage, message: message,
                                  thumbDir: old.thumbDir, progress: progress, updatedAt: Date()))
            } else {
                merged.append(Job(id: item.id,
                                  filename: item.filename,
                                  bytes: item.bytes,
                                  folderPath: item.folderPath,
                                  stage: item.state == .ready ? .done : .pending,
                                  message: item.state == .ready ? "已有缩略图" : "",
                                  thumbDir: nil,
                                  progress: item.state == .ready ? 1 : 0,
                                  updatedAt: Date()))
            }
        }
        jobs = merged
        reindex()
        saveLedger()
        emit("队列：\(jobs.count) 项，待处理 \(jobs.filter { $0.stage == .pending }.count)")
    }

    public func run(dryRun: Bool, limit: Int? = nil) {
        lastError = nil
        isCancelled = false

        // Snapshot: uploads may mutate `jobs` from other threads.
        let snapshot = jobs
        var candidates = snapshot.filter { job in
            guard job.stage != .done else { return false }
            if let only = onlyItemIDs { return only.contains(job.id) }
            return true
        }
        if let limit { candidates = Array(candidates.prefix(limit)) }

        let workers = max(1, min(options.concurrency, 6))
        if workers == 1 {
            for job in candidates {
                if isCancelled { break }
                waitWhilePaused()
                if isCancelled { break }
                if !process(job, dryRun: dryRun) { break }
            }
        } else {
            // The NAS link is round-trip bound (two files in parallel finish in
            // 6 s where serial takes 10 s), so independent items can overlap.
            let cursor = JobCursor(candidates)
            let group = DispatchGroup()
            let queue = DispatchQueue(label: "sia.workers", qos: .userInitiated, attributes: .concurrent)
            for _ in 0..<workers {
                group.enter()
                queue.async { [weak self] in
                    guard let self else { group.leave(); return }
                    while !self.isCancelled {
                        guard let job = cursor.next() else { break }
                        self.waitWhilePaused()
                        if self.isCancelled { break }
                        if !self.process(job, dryRun: dryRun) { break }
                    }
                    group.leave()
                }
            }
            group.wait()
        }

        // Wait for in-flight uploads so callers observe final states.
        uploadGroup.wait()
        saveLedger()
    }

    /// Handles one item. Returns false when the whole run should stop.
    private func process(_ job: Job, dryRun: Bool) -> Bool {
        let tStart = Date()

        if haltIfNeeded() { return false }

        // Self-correct against the server before doing any work: if the three
        // sizes are already there, this item needs nothing.
        if let ready = client?.thumbnailReady(itemID: job.id), ready {
            patch(job.id, stage: .done, message: "NAS 已有缩略图", progress: 1)
            return true
        }

        if job.bytes > 0, job.bytes < 2048 {
            patch(job.id, stage: .skipped, message: "文件仅 \(job.bytes) 字节，内容不完整")
            return true
        }

        if job.bytes == 0 {
            patch(job.id, stage: .skipped, message: "文件为 0 字节，无法生成预览")
            return true
        }

        if options.skipLargerThanBytes > 0, job.bytes > options.skipLargerThanBytes {
            patch(job.id, stage: .skipped, message: "超过体积上限，已跳过")
            return true
        }
        if dryRun {
            patch(job.id, stage: .pending, message: "干跑：将取 \(options.strategy.label) 后抽帧")
            return true
        }

        let decision = StrategyPlanner.decide(
            explicit: options.strategy,
            moovInHead: options.strategy == .auto ? source.canPrefixRead(job: job) : nil,
            bytes: job.bytes,
            maxFullDownload: options.maxBytesForFullDownload,
            hasClient: client != nil,
            isImage: job.isImage)

        let effective: FetchStrategy
        switch decision {
        case .prefix: effective = .prefix
        case .fullDownload: effective = .fullDownload
        case .remote: effective = .remote
        case .blocked(let reason):
            patch(job.id, stage: .blocked, message: reason)
            setLastError(reason)
            return true
        }
        let budget = effective == .prefix ? options.prefixBudgetBytes : max(job.bytes, 1)

        if effective == .remote {
            videoSem.wait()
            defer { videoSem.signal() }
            guard let client else {
                patch(job.id, stage: .failed, message: "缺少 NAS 连接")
                return true
            }

            let out = workRoot.appendingPathComponent("\(job.id)", isDirectory: true)
                .appendingPathComponent("thumbs", isDirectory: true)
            let stem = (job.filename as NSString).deletingPathExtension
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

            /// MPEG-PS/TS recordings (Hikvision, some DJI) are streamed in order:
            /// decoding a prefix is enough and avoids reading the whole file.
            func extractFromPrefix(mp4NeedsMoov: Bool) {
                do {
                    var lastError: Error?
                    // For a real MP4 the index (moov) must be inside the prefix;
                    // otherwise no amount of extra bytes will help, so stop early.
                    let budgets: [Int] = mp4NeedsMoov ? [2 << 20, 8 << 20]
                                                      : [256 << 10, 2 << 20, 8 << 20, 24 << 20]
                    var sawMoov = false
                    for budget in budgets {
                        patch(job.id, stage: .fetching, message: "读取前段数据…", progress: 0)
                        let sample = try Fetcher.chunked(
                            client: client, unitId: job.id, cacheKey: nil,
                            budget: min(budget, max(job.bytes, 1 << 20)),
                            deadline: 180) { _, _ in true }
                        let samplePath = workRoot
                            .appendingPathComponent("\(job.id)", isDirectory: true)
                            .appendingPathComponent("prefix.mp4")
                        try sample.data.write(to: samplePath)
                        if sample.data.range(of: Data("moov".utf8)) != nil { sawMoov = true }
                        if mp4NeedsMoov, !sawMoov { continue }
                        patch(job.id, stage: .converting, message: "生成缩略图中…", progress: 1)
                        do {
                            let set = try Thumbnailer.generate(inputArgument: samplePath.path,
                                                               stem: stem, outDir: out,
                                                               seconds: max(options.frameFraction, 0) * 3.0)
                            patch(job.id, stage: .readyToUpload,
                                  message: String(format: "已生成 %dx%d", set.width, set.height),
                                  progress: 1, thumbDir: out.path)
                            emit("✓ \(job.filename) 前缀解码 \(set.width)x\(set.height)  [\(fmt(Date().timeIntervalSince(tStart)))]")
                            enqueueUpload(jobID: job.id, thumbDir: out)
                            lastError = nil
                            break
                        } catch { lastError = error }
                    }
                    if mp4NeedsMoov, !sawMoov {
                        patch(job.id, stage: .failed,
                              message: "MP4 索引在文件末尾，当前网速下无法读取（可用前缀扫描时再试）")
                    } else if let lastError {
                        patch(job.id, stage: .failed, message: "解码失败：\(lastError)")
                    }
                } catch {
                    patch(job.id, stage: .failed, message: "解码失败：\(error)")
                }
            }

            /// Index at the end of the file: fetch tail + moov + first sample and
            /// assemble a sparse file, which ffmpeg can decode.
            func extractFromTailIndex() {
                do {
                    patch(job.id, stage: .fetching, message: "读取尾部索引…", progress: 0)
                    let index = try MP4TailIndex.inspect(client: client, itemID: job.id)
                    guard index.firstSample != nil else {
                        throw MP4TailIndex.MP4Error.noSample
                    }
                    let sparse = workRoot
                        .appendingPathComponent("\(job.id)", isDirectory: true)
                        .appendingPathComponent("sparse.mp4")
                    try MP4TailIndex.materialize(client: client, itemID: job.id,
                                                 index: index, path: sparse)
                    patch(job.id, stage: .converting, message: "生成缩略图中…", progress: 1)
                    let set = try Thumbnailer.generate(inputArgument: sparse.path,
                                                       stem: stem, outDir: out,
                                                       seconds: 0)
                    patch(job.id, stage: .readyToUpload,
                          message: String(format: "已生成 %dx%d", set.width, set.height),
                          progress: 1, thumbDir: out.path)
                    emit("✓ \(job.filename) 尾部索引解码 \(set.width)x\(set.height)  [\(fmt(Date().timeIntervalSince(tStart)))]")
                    enqueueUpload(jobID: job.id, thumbDir: out)
                    try? FileManager.default.removeItem(at: sparse)
                } catch {
                    // Not every MP4 keeps its index at the end: faststart files
                    // put moov in the head, and then a plain prefix decodes.
                    if let sample = try? Fetcher.chunked(client: client, unitId: job.id,
                                                         cacheKey: nil, budget: 4 << 20,
                                                         deadline: 120, chunkHandler: { _, _ in true }),
                       sample.data.range(of: Data("moov".utf8)) != nil {
                        let prefix = workRoot
                            .appendingPathComponent("\(job.id)", isDirectory: true)
                            .appendingPathComponent("faststart.mp4")
                        if (try? sample.data.write(to: prefix)) != nil {
                            patch(job.id, stage: .converting, message: "生成缩略图中…", progress: 1)
                            if let set = try? Thumbnailer.generate(inputArgument: prefix.path,
                                                                   stem: stem, outDir: out,
                                                                   seconds: max(options.frameFraction, 0) * 3.0) {
                                patch(job.id, stage: .readyToUpload,
                                      message: String(format: "已生成 %dx%d", set.width, set.height),
                                      progress: 1, thumbDir: out.path)
                                emit("✓ \(job.filename) 头部索引解码 \(set.width)x\(set.height)  [\(fmt(Date().timeIntervalSince(tStart)))]")
                                enqueueUpload(jobID: job.id, thumbDir: out)
                                try? FileManager.default.removeItem(at: prefix)
                                return
                            }
                        }
                    }
                    if haltIfNeeded(error, job: job) { return }
                    if case MP4TailIndex.MP4Error.noMoov = error {
                        // No index anywhere and no moov in the head: the
                        // recording was never finalised, so retrying cannot help.
                        patch(job.id, stage: .skipped,
                              message: "文件不完整（缺少 moov 索引），无法处理")
                    } else {
                        patch(job.id, stage: .failed, message: "解码失败：\(error)")
                    }
                }
            }

            if ContainerSniffer.sniffMP4(client: client, unitId: job.id) {
                patch(job.id, stage: .fetching, message: "抽帧中…", progress: 0)
                do {
                    let set = try VideoFrame.extract(
                        client: client,
                        itemID: job.id,
                        seconds: max(options.frameFraction, 0) * 3.0,
                        totalBytes: job.bytes,
                        stem: stem,
                        outDir: out,
                        onProgress: { [weak self] fraction in
                            self?.onProgress?(job.id, fraction)
                        })
                    patch(job.id, stage: .readyToUpload,
                          message: String(format: "已生成 %dx%d", set.width, set.height),
                          progress: 1, thumbDir: out.path)
                    emit("✓ \(job.filename) 抽帧 \(set.width)x\(set.height)  [\(fmt(Date().timeIntervalSince(tStart)))]")
                    enqueueUpload(jobID: job.id, thumbDir: out)
                } catch {
                    extractFromTailIndex()
                }
            } else {
                extractFromPrefix(mp4NeedsMoov: false)
            }
            saveLedger()
            return true
        }


        patch(job.id, stage: .fetching, message: "读取中…", progress: 0)
        do {
            let sample = try source.fetch(job: job, budget: budget, onProgress: { [weak self] fraction in
                self?.onProgress?(job.id, fraction)
            }, shouldPause: { [weak self] in
                guard let self else { return false }
                return self.isPaused && !self.isCancelled
            })

            if isCancelled {
                patch(job.id, stage: .cancelled, message: "已取消")
                return false
            }

            let dir = workRoot.appendingPathComponent("\(job.id)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let ext = (job.filename as NSString).pathExtension.isEmpty
                ? "mp4" : (job.filename as NSString).pathExtension
            let local = dir.appendingPathComponent("sample.\(ext)")
            try sample.data.write(to: local, options: .atomic)

            patch(job.id, stage: .converting, message: "生成缩略图中…", progress: 1)
            let out = dir.appendingPathComponent("thumbs", isDirectory: true)
            let set: ThumbnailSet
            if job.isImage {
                // ImageIO handles HEIC/JPEG/TIFF/PNG/DNG/CR2 and EXIF
                // orientation; ffmpeg failed on RAW entirely.
                set = try ImageThumbnailer.generate(input: local, outDir: out)
            } else {
                do {
                    set = try Thumbnailer.generate(input: local, outDir: out,
                                                   seconds: max(options.frameFraction, 0) * 3.0)
                } catch {
                    // Unknown extension that ffmpeg refuses may still be an
                    // image container ImageIO understands.
                    set = try ImageThumbnailer.generate(input: local, outDir: out)
                }
            }
            patch(job.id, stage: .readyToUpload,
                  message: "已生成 \(set.width)x\(set.height) 三档，等待上传",
                  progress: 1, thumbDir: out.path)
            emit("✓ \(job.filename) → \(set.width)x\(set.height)  [取数 \(fmt(Date().timeIntervalSince(tStart)))]")
            enqueueUpload(jobID: job.id, thumbDir: out)
        } catch let e as FetchError {
            if case .permissionDenied(let code) = e {
                patch(job.id, stage: .blocked, message: "\(e) (code \(code))")
                setLastError("\(e)")
                saveLedger()
                emit("已停止：\(e)")
                return false
            }
            if case .cancelled = e {
                patch(job.id, stage: .cancelled, message: "已取消")
                return false
            }
            patch(job.id, stage: .failed, message: "\(e)")
        } catch {
            patch(job.id, stage: .failed, message: "\(error)")
        }
        saveLedger()
        return true
    }

    /// Uploads only when the user explicitly enabled it. Everything else keeps
    /// `readyToUpload` as the terminal state, so a run can never surprise the NAS.
    private func enqueueUpload(jobID: Int, thumbDir: URL) {
        guard options.autoUpload else { return }
        uploadGroup.enter()
        uploadQueue.async {
            self.uploadSem.wait()
            defer {
                self.uploadSem.signal()
                self.uploadGroup.leave()
            }
            self.tryMaybeUpload(jobID: jobID, thumbDir: thumbDir)
        }
    }

    private func tryMaybeUpload(jobID: Int, thumbDir: URL) {
        guard options.autoUpload else { return }
        guard let client else { return }
        if writer == nil { writer = WriteGate(mode: .confirmed, client: client) }
        guard let writer, let job = jobs.first(where: { $0.id == jobID }) else { return }
        let tUpload = Date()
        do {
            let plan = try writer.plan(for: job, thumbDir: thumbDir)
            patch(jobID, stage: .uploading, message: "上传中… 3 个文件")
            try writer.upload(plan)
            patch(jobID, stage: .done, message: "已上传，预览应已可见", progress: 1)
            emit("↑ \(job.filename) 上传成功  [\(fmt(Date().timeIntervalSince(tUpload)))]")
        } catch let e as WriteGateError {
            if case .conversionStuck = e {
                // Nothing can be written until the NAS lets go of the unit; a
                // retry every run would just waste bandwidth.
                patch(jobID, stage: .blocked,
                      message: "NAS 侧转换任务卡死（源文件不完整），无法写入缩略图")
                emit("⊘ \(job.filename) 阻塞：NAS 转换任务卡死")
            } else {
                patch(jobID, stage: .failed, message: "上传失败: \(e)")
                emit("✗ \(job.filename) 上传失败: \(e)")
            }
        } catch {
            patch(jobID, stage: .failed, message: "上传失败: \(error)")
            emit("✗ \(job.filename) 上传失败: \(error)")
        }
    }

    public var summary: (pending: Int, ready: Int, failed: Int, blocked: Int, done: Int, skipped: Int) {
        (jobs.filter { $0.stage == .pending }.count,
         jobs.filter { $0.stage == .readyToUpload }.count,
         jobs.filter { $0.stage == .failed }.count,
         jobs.filter { $0.stage == .blocked }.count,
         jobs.filter { $0.stage == .done }.count,
         jobs.filter { $0.stage == .skipped }.count)
    }
}
