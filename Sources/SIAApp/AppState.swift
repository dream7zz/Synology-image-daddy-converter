import SwiftUI
import AppKit
import SIACore
import AVFoundation

struct FolderNode: Identifiable {
    let id: String
    let name: String
    var children: [FolderNode]
    var total: Int
    var missing: Int
}

enum Phase: Equatable {
    case idle, scanning, running, paused, finished
}

// MARK: - Thumbnails

/// Bounds concurrency without blocking a thread: awaiting a slot suspends,
/// whereas DispatchSemaphore.wait() would pin a cooperative-pool thread.
actor AsyncGate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(_ slots: Int) { free = slots }

    func acquire() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            waiters.append(c)
        }
    }

    func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            free += 1
        }
    }
}

@MainActor
final class ThumbnailStore: ObservableObject {
    @Published private(set) var images: [Int: NSImage] = [:]
    /// NSCache-style bound: decoded 1280px images are several MB each, so an
    /// unbounded dictionary grew to gigabytes while scrolling.
    private var imageOrder: [Int] = []
    private let imageLimit = 400

    private func store(_ image: NSImage, for id: Int) {
        if images[id] == nil { imageOrder.append(id) }
        images[id] = image
        while imageOrder.count > imageLimit {
            let old = imageOrder.removeFirst()
            images[old] = nil
        }
    }
    /// Bumped when failures are cleared, so cards re-run their load task.
    @Published private(set) var generation = 0
    @Published private(set) var failed: Set<Int> = []

    /// Documentation/demo mode: placeholders instead of NAS requests.
    var demo = false
    var demoItems: [Int: PhotoItem] = [:]

    private var client: ThumbnailClient?
    private var inFlight: Set<Int> = []
    /// Cap simultaneous requests; the NAS dislikes dozens of parallel fetches
    /// and it kept the UI from flooding the network during a scan.
    private let gate = AsyncGate(5)

    func reset(account: Account, nasClient: NASClient) {
        images = [:]
        failed = []
        inFlight = []
        client = ThumbnailClient(client: nasClient, accountID: account.id)
    }

    func load(_ item: PhotoItem, size: ThumbnailClient.Size = .sm) {
        guard images[item.id] == nil, !inFlight.contains(item.id), !failed.contains(item.id) else { return }
        if demo {
            if let image = DemoMode.placeholder(for: item) { store(image, for: item.id) }
            return
        }
        guard let client else { return }
        inFlight.insert(item.id)
        // The thumbnail endpoint requires cache_key; items scanned without one
        // still need a value, and any value works.
        let cacheKey = item.cacheKey ?? "s\(item.id)"
        let id = item.id
        Task { [weak self] in
            guard let self else { return }
            await self.gate.acquire()
            let data = await client.thumbnailAsync(id: id, cacheKey: cacheKey, size: size)
            await self.gate.release()
            self.inFlight.remove(id)
            if let data, let img = NSImage(data: data) {
                self.store(img, for: id)
            } else {
                self.failed.insert(id)
            }
        }
    }

    /// Clears the failure set: a completed upload or a fresh scan should give
    /// every card another chance instead of showing a permanent placeholder.
    func resetFailures() {
        failed.removeAll()
        generation += 1
    }

    /// Drops any cached image so the card can pick up a freshly uploaded preview.
    func invalidate(_ id: Int) {
        images[id] = nil
        failed.remove(id)
        inFlight.remove(id)
    }

    /// Re-fetch after the NAS gained a preview. The old cache key is stale, so
    /// this deliberately asks without one.
    func refresh(_ item: PhotoItem) {
        invalidate(item.id)
        if demo {
            if let image = DemoMode.placeholder(for: item) { store(image, for: item.id) }
            return
        }
        guard let client else { return }
        let id = item.id
        // The endpoint answers 200+JSON when cache_key is absent; any value
        // works, it only busts the server/client cache.
        let bust = "r\(Int(Date().timeIntervalSince1970))"
        inFlight.insert(id)
        Task.detached(priority: .utility) {
            var data = client.thumbnail(id: id, cacheKey: bust, size: .sm)
            // Uploads are indexed a moment later; retry briefly.
            var attempt = 0
            while data == nil, attempt < 3 {
                Thread.sleep(forTimeInterval: 1.5)
                data = client.thumbnail(id: id, cacheKey: "\(bust)\(attempt)", size: .sm)
                attempt += 1
            }
            await MainActor.run {
                self.inFlight.remove(id)
                if let data, let image = NSImage(data: data) {
                    self.store(image, for: id)
                } else {
                    self.failed.insert(id)
                }
            }
        }
    }

    /// Shared client so the inspector warms the same cache as the grid.
    func image(id: Int, cacheKey: String?, size: ThumbnailClient.Size) async -> NSImage? {
        if demo {
            if let cached = images[id] { return cached }
            if let item = demoItems[id], let image = DemoMode.placeholder(for: item) {
                store(image, for: id)
                return image
            }
            return nil
        }
        guard let client else { return nil }
        await gate.acquire()
        let data = await client.thumbnailAsync(id: id, cacheKey: cacheKey, size: size)
        await gate.release()
        guard let data else { return nil }
        return NSImage(data: data)
    }
}

// MARK: - App state

@MainActor
final class AppState: ObservableObject {
    /// `Engine.run` blocks on network and file I/O for a whole batch. Running it
    /// inline in a Task pins a cooperative-pool thread the entire time, so it
    /// gets a dedicated queue and the caller awaits completion.
    private static let engineQueue = DispatchQueue(label: "sia.engine", qos: .utility)

    func runEngineOffPool(_ engine: Engine) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            Self.engineQueue.async {
                engine.run(dryRun: false)
                c.resume()
            }
        }
    }

    enum Filter: String, CaseIterable, Identifiable {
        case missing = "缺失", invalid = "无效", ready = "就绪", failed = "失败", all = "全部"
        var id: String { rawValue }
    }
    enum ViewMode: String, CaseIterable, Identifiable {
        case grid = "网格", table = "表格"
        var id: String { rawValue }
    }

    @Published var accounts: [Account] = AccountsStore.shared.accounts
    @Published var selectedAccountID: UUID?
    @Published var items: [PhotoItem] = []
    @Published var jobs: [Int: Job] = [:]
    @Published var phase: Phase = .idle
    @Published var filter: Filter = .missing
    @Published var viewMode: ViewMode = .grid
    @Published var search = ""
    @Published var selectedItemID: Int?
    /// Folder the user drilled into; nil means the whole library. This is
    /// derived from whatever the account can actually see — nothing is hardcoded.
    @Published var selectedFolder: String?
    /// Full folder list from the NAS, including folders without media.
    @Published var folderEntries: [FolderEntry] = []
    /// Human-readable scan progress, shown in the strip while scanning.
    @Published var scanStatus: String?
    /// Immediate children of the root, offered for scanning.
    @Published var rootFolders: [FolderEntry] = []
    /// Folder paths ticked by the user; drives both scanning and processing.
    @Published var selectedPaths: Set<String> = []
    /// Roots whose contents are loaded.
    @Published var scannedRoots: [FolderEntry] = []
    /// What the ledger says about each item. Together with the NAS verdict this
    /// is the only source of truth for "does it have thumbnails".
    @Published private(set) var ledgerStages: [Int: JobStage] = [:]
    /// Items this tool already finished (persisted separately by the engine).
    @Published private(set) var doneItems: Set<Int> = []

    /// Items whose file is literally 0 bytes — unprocessable leftovers.
    @Published var zeroByteItems: [PhotoItem] = []
    @Published var selectedZeroIDs: Set<Int> = []
    @Published var showZeroByteSheet = false
    /// Deletion needs permission the current account does not have yet.
    @Published var canDeleteOnNAS = false
    @Published var expandedFolders: Set<String> = []
    @Published var log: [String] = []
    @Published var showLogin = false
    @Published var showSettings = false
    @Published var viewingItemID: Int?
    /// Live per-item download fraction straight from the engine callback.
    @Published var liveProgress: [Int: Double] = [:]
    @Published var startedAt: Date?
    /// Ids that finished this run but whose PhotoItem has not been updated yet.
    /// Missing count inside the ticked scope when the run started.
    private var runScopeBaseline: Int?
    /// Paths this run was built from; changing the ticks mid-run must not
    /// change what the queue and the progress bar report.
    private var runScopePaths: Set<String> = []
    private var lastScopeScanAt: Date?
    /// Epoch seconds of the newest item present when the scope was last scanned.
    private var lastScopeNewest: Int?

    private struct ScanState: Codable {
        var newest: Int?
        var paths: [String]
        var at: Date
    }

    private func scanStateURL(_ key: String) -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SIA-Lite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("scanstate-\(key).json")
    }

    private func saveScanState(key: String) {
        let state = ScanState(newest: lastScopeNewest,
                              paths: Array(lastScopeScanPaths),
                              at: lastScopeScanAt ?? Date())
        if let data = try? JSONEncoder().encode(state) {
            try? data.write(to: scanStateURL(key))
        }
    }

    private func loadScanState(key: String) {
        guard let data = try? Data(contentsOf: scanStateURL(key)),
              let state = try? JSONDecoder().decode(ScanState.self, from: data) else { return }
        lastScopeNewest = state.newest
        lastScopeScanPaths = Set(state.paths)
        lastScopeScanAt = state.at
    }
    private var lastScopeScanPaths: Set<String> = []
    private var pendingReadyIDs: Set<Int> = []
    private var readyFlushScheduled = false
    /// Finished count when the current run began, for ETA baseline.
    private var readyAtStart = 0
    /// Counts captured when a run starts, so finished items leave a trace.
    private var runBaseline: (total: Int, ready: Int)?

    // Coalesced UI updates: the engine reports several times per file, and
    // republishing a 1,000-entry dictionary each time re-rendered the whole grid.
    private var pendingJobs: [Int: Job] = [:]
    private var pendingProgress: [Int: Double] = [:]
    private var pendingClears: Set<Int> = []
    private var flushScheduled = false
    @Published var banner: String?
    @Published var options = EngineOptions() {
        didSet {
            guard let id = selectedAccountID else { return }
            SettingsStore.shared.save(options, key: id.uuidString)
        }
    }
    @Published var thumbnailStore = ThumbnailStore()

    private var engine: Engine?
    private var nasClient: NASClient?
    private var mediaProxy: MediaProxy?
    private var mediaProxyPort: UInt16?
    private var mediaLoader: NASMediaLoader?
    private let playerQueue = DispatchQueue(label: "sia.player", qos: .userInitiated)

    /// User-facing text instead of a raw NSURLError dump.
    static func friendly(_ error: Error) -> String {
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain {
            switch ns.code {
            case NSURLErrorCannotFindHost: return "无法解析 NAS 主机名，请检查网络或地址"
            case NSURLErrorCannotConnectToHost: return "无法连接到 NAS，请确认端口与网络"
            case NSURLErrorTimedOut: return "连接 NAS 超时"
            case NSURLErrorNotConnectedToInternet: return "网络未连接"
            default: return "网络错误（\(ns.code)）"
            }
        }
        return "\(error)"
    }

    var account: Account? {
        accounts.first { $0.id == selectedAccountID }
    }

    var client: NASClient? { nasClient }

    // MARK: derived

    /// Items inside the ticked folders. There is deliberately no separate
    /// "focused folder": clicking a row ticks it, so the tree and the grid can
    /// never disagree.
    var scopedItems: [PhotoItem] { items }

    // Cached aggregates: recomputing these over 167k items on every render was
    // the main reason the window felt frozen.
    private var countsDirty = true
    private var countsCache: (total: Int, ready: Int, missing: Int, invalid: Int, failed: Int) = (0, 0, 0, 0, 0)

    func invalidateCounts() { countsDirty = true }

    /// The one readiness rule used by every view: the NAS has all three sizes
    /// (from the scan) **or** we already uploaded them (from the ledger).
    func isReady(_ item: PhotoItem) -> Bool {
        item.state == .ready || doneItems.contains(item.id)
    }

    private func ledgerURL(key: String) -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SIA-Lite", isDirectory: true)
        return base.appendingPathComponent("ledger-\(key).json")
    }

    private func saveDoneList(key: String) {
        if let data = try? JSONEncoder().encode(Array(doneItems)) {
            try? data.write(to: doneURL(key: key), options: .atomic)
        }
    }

    /// Reconciles the local "we fixed this" list with the NAS verdict from a
    /// fresh scan: if the server no longer has the thumbnails, the item goes
    /// back to the queue instead of being silently considered done.
    private func reconcileDoneWithScan(key: String) {
        var done = doneItems
        var changed = false
        for item in items where item.state != .ready && done.contains(item.id) {
            done.remove(item.id)
            changed = true
        }
        if changed {
            doneItems = done
            saveDoneList(key: key)
            invalidateCounts()
            statsDirty = true
            folderTreeDirty = true
        }
    }

    private func doneURL(key: String) -> URL {
        ledgerURL(key: key).deletingLastPathComponent().appendingPathComponent("done-\(key).json")
    }

    func reloadLedger(key: String) {
        if let data = try? Data(contentsOf: doneURL(key: key)),
           let ids = try? JSONDecoder().decode([Int].self, from: data) {
            doneItems = Set(ids)
        } else {
            doneItems = []
        }
        guard let data = try? Data(contentsOf: ledgerURL(key: key)),
              let rows = try? JSONDecoder().decode([Job].self, from: data) else {
            ledgerStages = [:]
            return
        }
        var map: [Int: JobStage] = [:]
        for row in rows { map[row.id] = row.stage }
        ledgerStages = map
        invalidateCounts()
        statsDirty = true
        folderTreeDirty = true
    }

    /// Every visible counter comes from this one aggregate, so the sidebar,
    /// the filter rows and the queue can never disagree.
    private func aggregate() -> (total: Int, ready: Int, missing: Int,
                                 invalid: Int, failed: Int) {
        if countsDirty {
            let scope = selectedPaths.isEmpty ? [] : scopeItems
            var ready = 0, invalid = 0, failed = 0
            for item in scope {
                // Ready wins: a 400 KB clip that already has thumbnails is
                // fine, it is not "invalid data".
                if isReady(item) { ready += 1 }
                else if item.isInvalid { invalid += 1 }
                if [.failed, .blocked, .cancelled].contains(jobs[item.id]?.stage ?? .pending) {
                    failed += 1
                }
            }
            countsCache = (scope.count, ready, scope.count - ready - invalid, invalid, failed)
            countsDirty = false
        }
        return countsCache
    }

    var counts: (total: Int, ready: Int, missing: Int, failed: Int) {
        let a = aggregate()
        return (a.total, a.ready, a.missing, a.failed)
    }

    /// Hierarchical view of every folder the account can read. Built purely
    /// from the scan, so permissions changes show up on the next scan.
    private var folderTreeCache: [FolderNode] = []
    private var pendingScanItems: [PhotoItem] = []
    private var scanFlushScheduled = false

    /// Rebuilds folder counts once, instead of on every render.
    func rebuildFolderTree() {
        folderTreeCache = buildFolderTree()
    }

    private var folderTreeDirty = false

    var folderTree: [FolderNode] {
        if folderTreeCache.isEmpty || folderTreeDirty {
            folderTreeCache = buildFolderTree()
            folderTreeDirty = false
        }
        return folderTreeCache
    }

    /// Single tree for the sidebar: scanned folders with children, plus any
    /// root that has never been scanned (shown as a leaf until scanned).
    var displayTree: [FolderNode] {
        var tree = folderTree
        let known = Set(collectPaths(tree))
        for root in rootFolders where !known.contains(root.path) {
            tree.append(FolderNode(id: root.path, name: root.name, children: [],
                                   total: 0, missing: 0))
        }
        return tree.sorted { $0.name < $1.name }
    }

    private func collectPaths(_ nodes: [FolderNode]) -> [String] {
        nodes.flatMap { [$0.id] + collectPaths($0.children) }
    }

    private func buildFolderTree() -> [FolderNode] {
        // Built from the NAS folder list, so empty folders and levels deeper
        // than the media are included. Counts come from the scanned items.
        var counts: [String: (total: Int, missing: Int)] = [:]
        for item in items {
            let segments = item.folderPath.split(separator: "/").map(String.init)
            guard !segments.isEmpty else { continue }
            let missing = (isReady(item) || item.isInvalid) ? 0 : 1
            var walked: [String] = []
            for seg in segments {
                walked.append(seg)
                let path = "/" + walked.joined(separator: "/")
                var cur = counts[path] ?? (0, 0)
                cur.total += 1
                cur.missing += missing
                counts[path] = cur
            }
        }

        var children: [String: [String]] = [:]
        for entry in folderEntries {
            let parent = String(entry.path[..<entry.path.lastIndex(of: "/")!])
            children[parent, default: []].append(entry.path)
        }

        func parentPath(_ path: String) -> String {
            String(path[..<path.lastIndex(of: "/")!])
        }

        func build(_ path: String) -> FolderNode {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            let kids = (children[path] ?? []).sorted().map(build)
            let c = counts[path] ?? (0, 0)
            return FolderNode(id: path, name: name, children: kids, total: c.total, missing: c.missing)
        }

        return (children[""] ?? []).sorted().map(build)
    }

    var folderSummaries: [(path: String, total: Int, missing: Int)] {
        var map: [String: (Int, Int)] = [:]
        for item in items {
            let parts = item.folderPath.split(separator: "/").map(String.init)
            guard let first = parts.first else { continue }
            let path = "/" + first
            var cur = map[path] ?? (0, 0)
            cur.0 += 1
            if !isReady(item) { cur.1 += 1 }
            map[path] = cur
        }
        return map.map { (path: $0.key, total: $0.value.0, missing: $0.value.1) }
            .sorted { $0.path < $1.path }
    }

    var visibleItems: [PhotoItem] {
        // The grid mirrors the ticked folders: with nothing ticked there is
        // nothing to show, and unticked folders never appear.
        var list = selectedPaths.isEmpty ? [] : scopeItems
        switch filter {
        case .all: break
        case .ready: list = list.filter { isReady($0) }
        case .invalid: list = list.filter { $0.isInvalid && !isReady($0) }
        case .missing: list = list.filter { !isReady($0) && !$0.isInvalid }
        case .failed: list = list.filter { jobs[$0.id]?.stage == .failed }
        }
        let q = search.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty {
            list = list.filter {
                $0.filename.localizedCaseInsensitiveContains(q) ||
                $0.folderPath.localizedCaseInsensitiveContains(q)
            }
        }
        return list
    }

    var selectedItem: PhotoItem? {
        guard let id = selectedItemID else { return nil }
        return items.first { $0.id == id }
    }

    /// Overall progress over the current work queue (items that still need work).
    /// Progress across the queue this run actually built. Uses the same tally
    /// as the counters, so "done / total" and the category numbers agree.
    var overallProgress: (done: Int, total: Int, fraction: Double) {
        let t = queueTally
        guard t.total > 0 else { return (0, 0, 1) }
        let settled = t.done + t.skipped + t.failed
        return (t.done, t.total, Double(settled) / Double(t.total))
    }

    var activeJob: Job? {
        jobs.values.first { $0.stage == .fetching || $0.stage == .converting || $0.stage == .uploading }
    }

    /// Live queue breakdown shown in the sidebar while running.
    var stageCounts: [(String, Int)] {
        let order: [(JobStage, String)] = [(.pending, "排队"), (.fetching, "读取"),
                                           (.converting, "抽帧"), (.uploading, "上传"),
                                           (.done, "完成"), (.failed, "失败")]
        return order.compactMap { stage, name in
            let n = jobs.values.filter { $0.stage == stage }.count
            return n > 0 ? (name, n) : nil
        }
    }

    func stage(for id: Int) -> JobStage? { jobs[id]?.stage }

    var phaseText: String {
        switch phase {
        case .idle: return "空闲"
        case .scanning: return "扫描中"
        case .running: return "运行中"
        case .paused: return "已暂停"
        case .finished: return "已完成"
        }
    }

    private var statsDirty = true
    private var statsCache: (active: Int, pending: Int, ready: Int) = (0, 0, 0)

    private func refreshStats() {
        guard statsDirty else { return }
        var active = 0, pending = 0
        for job in jobs.values {
            if [.fetching, .converting, .uploading].contains(job.stage) { active += 1 }
            else if job.stage == .pending { pending += 1 }
        }
        var ready = 0
        for item in items where isReady(item) { ready += 1 }
        statsCache = (active, pending, ready)
        statsDirty = false
    }

    /// Queue counters read the live job map, so the header can never disagree
    /// with the rows the list is built from.
    /// Every number on the queue panel comes from this one tally, so the
    /// categories always add up to `total` (the queue that was built).
    struct QueueTally {
        var active = 0      // fetching / converting / uploading / readyToUpload
        var pending = 0
        var failed = 0
        var skipped = 0
        var done = 0
        var total: Int { active + pending + failed + skipped + done }
    }

    var queueTally: QueueTally {
        var t = QueueTally()
        for job in jobs.values {
            switch job.stage {
            case .fetching, .converting, .uploading, .readyToUpload: t.active += 1
            case .pending: t.pending += 1
            case .failed, .blocked, .cancelled: t.failed += 1
            case .skipped: t.skipped += 1
            case .done: t.done += 1
            }
        }
        return t
    }

    var queueStats: (active: Int, pending: Int, failed: Int, total: Int) {
        let t = queueTally
        return (t.active, t.pending, t.failed, t.total)
    }

    var activeCount: Int { queueStats.active }
    var pendingCount: Int { queueStats.pending }

    /// Queue rows: active work first, then ready-to-upload, queued, failures, done.
    enum JobFilter: CaseIterable {
        case active, pending, failed, skipped, done, all

        func matches(_ stage: JobStage) -> Bool {
            switch self {
            case .active: return [.fetching, .converting, .uploading, .readyToUpload].contains(stage)
            case .pending: return stage == .pending
            case .failed: return [.failed, .blocked, .cancelled].contains(stage)
            case .skipped: return stage == .skipped
            case .done: return stage == .done
            case .all: return true
            }
        }
    }

    private var queueVersion = 0
    private var pageCacheKey: String = ""
    private var pageCache: (rows: [Job], total: Int) = ([], 0)

    /// Paged, pre-filtered queue: buckets by stage instead of sorting 167k rows.
    func queuePage(filter: JobFilter, limit: Int) -> (rows: [Job], total: Int) {
        let key = "\(filter)\(limit)\(queueVersion)\(jobs.count)"
        if key == pageCacheKey { return pageCache }
        func rank(_ stage: JobStage) -> Int {
            switch stage {
            case .fetching: return 0
            case .converting: return 1
            case .uploading: return 2
            case .readyToUpload: return 3
            case .pending: return 4
            case .failed, .blocked, .cancelled: return 5
            case .skipped: return 6
            case .done: return 7
            }
        }
        var buckets = [[Job]](repeating: [], count: 8)
        for job in jobs.values where filter.matches(job.stage) {
            buckets[rank(job.stage)].append(job)
        }
        // Within a stage the freshest work goes first, so the rows that are
        // actually moving sit at the top instead of in id order.
        for i in buckets.indices {
            buckets[i].sort { $0.updatedAt > $1.updatedAt }
        }
        var rows: [Job] = []
        var total = 0
        for bucket in buckets {
            total += bucket.count
            guard rows.count < limit else { continue }
            rows.append(contentsOf: bucket.prefix(limit - rows.count))
        }
        pageCache = (rows, total)
        pageCacheKey = key
        // Must clear the flag, otherwise the key never changes and the list is
        // served from this first snapshot forever.
        queueRowsDirty = false
        return pageCache
    }

    private var queueRowsDirty = true
    private var queueRowsCache: [Job] = []
    private var lastQueueBuild = Date.distantPast

    func invalidateQueueRows() { queueRowsDirty = true }

    /// Counters for the ticked scope. Nothing ticked means nothing selected,
    /// not "the whole library".
    /// One canonical set of numbers: sidebar, folder tree and queue header all
    /// read from here so they can never disagree.
    var libraryCounts: (total: Int, ready: Int, missing: Int, empty: Int) {
        let a = aggregate()
        return (a.total, a.ready, a.missing, a.invalid)
    }

    var scopeCounts: (total: Int, ready: Int, missing: Int, failed: Int) {
        guard !selectedPaths.isEmpty else { return (0, 0, 0, 0) }
        let scope = scopeItems
        let ready = scope.reduce(into: 0) { $0 += (isReady($1) ? 1 : 0) }
        let invalid = scope.reduce(into: 0) { $0 += ($1.isInvalid ? 1 : 0) }
        return (scope.count, ready, scope.count - ready - invalid, 0)
    }

    var queueRows: [Job] {
        if !queueRowsDirty, Date().timeIntervalSince(lastQueueBuild) < 2 { return queueRowsCache }
        queueRowsCache = buildQueueRows()
        queueRowsDirty = false
        lastQueueBuild = Date()
        return queueRowsCache
    }

    private func buildQueueRows() -> [Job] {
        func rank(_ s: JobStage) -> Int {
            switch s {
            case .fetching: return 0
            case .converting: return 1
            case .uploading: return 2
            case .readyToUpload: return 3
            case .pending: return 4
            case .failed, .blocked, .cancelled: return 5
            case .skipped: return 6
            case .done: return 7
            }
        }
        return jobs.values.sorted {
            rank($0.stage) == rank($1.stage) ? $0.id < $1.id : rank($0.stage) < rank($1.stage)
        }
    }

    /// Failure reason without the transport prefixes, for the queue row.
    func failureText(_ job: Job) -> String {
        var text = job.message.trimmingCharacters(in: .whitespaces)
        for prefix in ["上传失败: NAS 拒绝了上传: ", "上传失败：", "上传失败: ", "解码失败："] {
            if text.hasPrefix(prefix) { text = String(text.dropFirst(prefix.count)); break }
        }
        return text.isEmpty ? "未知原因" : text
    }

    /// Prefer the job's own message when it is more specific than the stage
    /// (for example "抽帧中" instead of a generic "下载中").
    func stageLabel(_ job: Job) -> String {
        let message = job.message.trimmingCharacters(in: .whitespaces)
        if !message.isEmpty,
           [.fetching, .converting, .uploading].contains(job.stage) {
            let trimmed = message.hasSuffix("…") ? String(message.dropLast()) : message
            if !trimmed.isEmpty { return trimmed }
        }
        return stageLabel(job.stage)
    }

    func stageLabel(_ s: JobStage) -> String {
        switch s {
        case .pending: return "排队"
        case .fetching: return "下载中"
        case .converting: return "转换中"
        case .readyToUpload: return "已生成，待回传"
        case .uploading: return "回传中"
        case .done: return "完成"
        case .skipped: return "已跳过"
        case .blocked: return "被阻止"
        case .cancelled: return "已取消"
        case .failed: return "失败"
        }
    }

    /// Rough estimate from the average time per finished item.
    var etaText: String? {
        guard phase == .running, let started = startedAt else { return nil }
        let p = overallProgress
        let elapsed = Date().timeIntervalSince(started)
        // Only the missing items count as work; already-ready ones finish instantly.
        let finished = p.done
        guard finished >= 2, elapsed > 15, p.total > finished else { return nil }
        let perItem = elapsed / Double(finished)
        let seconds = Int(perItem * Double(p.total - finished))
        if p.total - finished <= 3 { return "即将完成" }
        if seconds < 60 { return "约 \(seconds) 秒" }
        if seconds < 3600 { return "约 \(seconds / 60) 分钟" }
        return String(format: "约 %.1f 小时", Double(seconds) / 3600)
    }

    /// Stage fractions for the queue window: download / convert / upload.
    /// Only download has real granularity; the other two are binary plus an
    /// "active" flag the UI renders as a pulse instead of a fake number.
    func stageFractions(for id: Int) -> (down: Double, conv: Double, up: Double, busy: JobStage?) {
        guard let job = jobs[id] else { return (0, 0, 0, nil) }
        switch job.stage {
        case .pending:      return (0, 0, 0, nil)
        case .fetching:     return (liveProgress[id] ?? job.progress, 0, 0, .fetching)
        case .converting:   return (1, 0, 0, .converting)
        case .readyToUpload:return (1, 1, 0, nil)
        case .uploading:    return (1, 1, 0, .uploading)
        case .done:         return (1, 1, 1, nil)
        case .failed, .blocked, .cancelled, .skipped: return (0, 0, 0, nil)
        }
    }
    func progress(for id: Int) -> Double { jobs[id]?.progress ?? 0 }
    func message(for id: Int) -> String { jobs[id]?.message ?? "" }

    /// Loads the synthetic library used for documentation screenshots.
    func bootstrapDemo() {
        let snap = DemoMode.snapshot()
        accounts = [snap.account]
        selectedAccountID = snap.account.id
        items = snap.items
        rootFolders = snap.roots
        folderEntries = snap.folders
        scannedRoots = snap.roots
        selectedPaths = Set(snap.roots.map(\.path))
        jobs = snap.jobs
        thumbnailStore.demo = true
        thumbnailStore.demoItems = Dictionary(uniqueKeysWithValues: snap.items.map { ($0.id, $0) })
        phase = snap.running ? .running : .idle
        filter = .all
        invalidateCounts()
        statsDirty = true
        folderTreeDirty = true
        rebuildFolderTree()
        banner = "演示模式：数据为本地生成，未连接任何 NAS"
    }

    // MARK: account

    func select(_ account: Account) {
        guard account.id != selectedAccountID else { return }
        stop()
        selectedAccountID = account.id
        // Keep the previous list on screen while the cache/log-in settles;
        // clearing here made the window flash "还没有扫描".
        jobs = [:]
        phase = .idle
        selectedItemID = nil
        banner = nil
        var acc = account
        acc.lastUsedAt = Date()
        AccountsStore.shared.upsert(acc)
        accounts = AccountsStore.shared.accounts

        guard AccountsStore.shared.hasPassword(for: account) else {
            banner = "该账号还没有保存密码，请重新登录"
            return
        }
        let tLoad = Date()
        if let cached = InventoryStore.load(key: account.id.uuidString) {
            var seen = Set<Int>()
            items = cached.items.filter { seen.insert($0.id).inserted }
            invalidateCounts()
            statsDirty = true
            reconcileSelection()
            scannedRoots = cached.scannedRoots ?? []
            selectedPaths = Set(scannedRoots.map(\.path))
            folderEntries = cached.folders
            rebuildFolderTree()
            AppState.appendRunLog("缓存载入：\(cached.items.count) 项，耗时 \(String(format: "%.1f", Date().timeIntervalSince(tLoad)))s")
        }
        loadScanState(key: account.id.uuidString)
        reloadLedger(key: account.id.uuidString)
        options = SettingsStore.shared.load(key: account.id.uuidString)
        // Fixed behaviour, not a preference: generate then upload.
        options.autoUpload = true
        // Fixed at 6; the setting is no longer exposed.
        options.concurrency = 6
        nasClient = AccountsStore.shared.client(for: account)
        thumbnailStore.reset(account: account, nasClient: nasClient!)
        do {
            try nasClient?.login()
            // 160k items take minutes to walk; show the cached result at once
            // and only refresh automatically when it is clearly stale.
            loadRootFolders()
            if items.isEmpty {
                banner = "先在上方选择要扫描的目录，然后点「扫描所选」"
            } else {
                banner = "已载入 \(items.count) 项。需要更多内容就再选目录扫描"
            }
        } catch {
            banner = "登录失败：" + Self.friendly(error)
        }
    }

    func addAccount(displayName: String, host: String, username: String, password: String) async -> String? {
        let probe = NASClient(host: host, account: username, password: password)
        do {
            try probe.login()
        } catch {
            return "连接失败：" + Self.friendly(error)
        }
        let account = Account(displayName: displayName.isEmpty ? username : displayName,
                              host: host, username: username)
        guard AccountsStore.shared.storePassword(password, for: account) else {
            return "无法写入系统钥匙串"
        }
        AccountsStore.shared.upsert(account)
        accounts = AccountsStore.shared.accounts
        showLogin = false
        select(account)
        return nil
    }

    func logout() {
        guard let account else { return }
        AccountsStore.shared.deletePassword(for: account)
        stop()
        items = []
        jobs = [:]
        banner = "已登出（账号与历史保留）"
    }

    func removeSelectedAccount() {
        guard let account else { return }
        AccountsStore.shared.remove(account)
        accounts = AccountsStore.shared.accounts
        selectedAccountID = nil
        items = []
        jobs = [:]
        nasClient = nil
        phase = .idle
    }

    // MARK: run

    var isBusy: Bool { phase == .running || phase == .scanning }

    /// How many top-level folders are effectively ticked (children included).
    var selectedRootCount: Int {
        rootFolders.filter { pathIsSelected($0.path) }.count
    }

    var allRootsSelected: Bool {
        !rootFolders.isEmpty && rootFolders.allSatisfy { pathIsSelected($0.path) }
    }

    func toggleAllRoots() {
        if allRootsSelected {
            selectedPaths.removeAll()
        } else {
            selectedPaths = Set(rootFolders.map(\.path))
        }
        runScopeBaseline = nil
        invalidateCounts()
        statsDirty = true
    }

    func togglePath(_ path: String) {
        if selectedPaths.contains(path) {
            selectedPaths.remove(path)
        } else if pathIsSelected(path) {
            // Covered by an ancestor: re-scope to exactly this folder instead of
            // silently doing nothing.
            selectedPaths = selectedPaths.filter { !path.hasPrefix($0 + "/") }
            selectedPaths.insert(path)
        } else {
            selectedPaths.insert(path)
            // Drop descendants that the new tick already covers.
            selectedPaths = selectedPaths.filter { !$0.hasPrefix(path + "/") }
        }
        runScopeBaseline = nil
        invalidateCounts()
        statsDirty = true
    }

    /// Items inside any ticked folder (prefix match covers subfolders).
    var scopeItems: [PhotoItem] {
        guard !selectedPaths.isEmpty else { return [] }
        return items.filter { item in
            selectedPaths.contains { item.folderPath == $0 || item.folderPath.hasPrefix($0 + "/") }
        }
    }

    /// Ticks are restored from the cached "scanned roots" no matter which
    /// async loader (cache or root list) finishes last.
    private func reconcileSelection() {
        guard !rootFolders.isEmpty else { return }
        if scannedRoots.isEmpty, !items.isEmpty {
            scannedRoots = rootFolders
        }
        if selectedPaths.isEmpty, !scannedRoots.isEmpty {
            selectedPaths = Set(scannedRoots.map(\.path))
        }
    }

    /// Human label for the current scope, shown in the progress strip.
    var scopeLabel: String {
        let paths = (phase != .idle && !runScopePaths.isEmpty) ? runScopePaths : selectedPaths
        if paths.count == 1, let only = paths.first {
            return only.split(separator: "/").last.map(String.init) ?? only
        }
        return paths.isEmpty ? "未选择" : "\(paths.count) 个目录"
    }

    func pathIsSelected(_ path: String) -> Bool {
        // A child inherits its parent's selection, so the tree reads correctly.
        if selectedPaths.contains(path) { return true }
        return selectedPaths.contains { path.hasPrefix($0 + "/") }
    }

    /// Only the root's immediate children: one request, so opening the app is
    /// instant even with 100k+ files.
    func loadRootFolders() {
        guard let nasClient else { return }
        Task.detached(priority: .userInitiated) {
            let roots = (try? Scanner(client: nasClient).rootFolders()) ?? []
            await MainActor.run {
                self.rootFolders = roots
                if self.scannedRoots.isEmpty, !self.items.isEmpty {
                    // Cache written before folder selection existed: it holds a
                    // full scan, so mark every root as loaded.
                    self.scannedRoots = roots
                    self.selectedPaths = Set(roots.map(\.path))
                } else if self.selectedPaths.isEmpty {
                    self.selectedPaths = Set(self.scannedRoots.map(\.path))
                }
                self.reconcileSelection()
                // Cache and root list load in parallel; whichever finishes last
                // used to leave the ticks empty.
                if self.selectedPaths.isEmpty, !self.scannedRoots.isEmpty {
                    self.selectedPaths = Set(self.scannedRoots.map(\.path))
                }
                // Recovery hook: re-walk every root and rebuild the cache.
                if ProcessInfo.processInfo.environment["SIA_RESCAN_ALL"] == "1" {
                    self.selectedPaths = Set(roots.map(\.path))
                    self.invalidateCounts()
                    self.scanSelected(roots: roots)
                }
                // Test hook: restrict the scope to one folder by name.
                if let only = ProcessInfo.processInfo.environment["SIA_SCOPE_ONLY"]?
                        .trimmingCharacters(in: .whitespaces),
                   let hit = roots.first(where: { $0.name == only }) {
                    self.selectedPaths = [hit.path]
                    self.invalidateCounts()
                    self.statsDirty = true
                }
            }
        }
    }

    /// Scans exactly the ticked subtrees and keeps whatever was scanned before.
    /// Refreshes only the folders this run touched. Re-walking every scanned
    /// root after finishing one folder was needless work.
    func rescanRunScope() {
        let scope = runScopePaths.isEmpty ? selectedPaths : runScopePaths
        guard !scope.isEmpty else { return }
        // Narrow further: only folders that actually had jobs this run.
        let touched = scope.filter { path in
            let base = path.hasSuffix("/") ? String(path.dropLast()) : path
            return jobs.values.contains { job in
                job.folderPath == base || job.folderPath.hasPrefix(base + "/")
            }
        }
        let paths = touched.isEmpty ? scope : touched
        let known = rootFolders + scannedRoots + folderEntries
        let chosen = paths.compactMap { path in known.first { $0.path == path } }
        guard !chosen.isEmpty else { return }
        scanSelected(roots: chosen)
    }

    /// Collects every 0-byte file in the scanned library.
    func collectZeroByteItems() {
        zeroByteItems = items.filter { $0.isInvalid && !isReady($0) }
            .sorted { $0.folderPath < $1.folderPath }
        selectedZeroIDs = Set(zeroByteItems.map(\.id))
    }

    func toggleZero(_ id: Int) {
        if selectedZeroIDs.contains(id) { selectedZeroIDs.remove(id) }
        else { selectedZeroIDs.insert(id) }
    }

    var zeroBytesCSV: String {
        var out = "id,size,bytes,path,filename\n"
        for item in zeroByteItems {
            let name = item.filename.replacingOccurrences(of: ",", with: "，")
            out += "\(item.id),0,\(item.bytes),\(item.folderPath),\(name)\n"
        }
        return out
    }

    func deleteSelectedZeroByteFiles() {
        guard canDeleteOnNAS else {
            banner = "当前账号没有删除权限，无法执行。可先导出清单，授权后再删除。"
            return
        }
        // Implemented once delete permission exists.
        banner = "删除接口待接入"
    }

    func scanSelected(roots: [FolderEntry]? = nil, completion: (() -> Void)? = nil) {
        if DemoMode.isOn { banner = "演示模式：不会连接 NAS"; return }
        guard let account, let nasClient, !isBusy else { return }
        let known = rootFolders + scannedRoots + folderEntries
        // Resolve ids for every ticked path, including deeper ones already seen.
        let chosen: [FolderEntry]
        if let roots {
            chosen = roots
        } else {
            chosen = selectedPaths.compactMap { path in
                known.first { $0.path == path }
            }
        }
        let unique = Dictionary(grouping: chosen, by: \.path).compactMap { $0.value.first }
        guard !unique.isEmpty else {
            banner = "先勾选要扫描的目录"
            return
        }

        phase = .scanning
        scanStatus = "准备扫描…"
        let key = account.id.uuidString
        let paths = unique.map(\.path)
        AppState.appendRunLog("扫描开始：#\(unique.count) 个目录 \(paths.prefix(3).joined(separator: " | "))")
        // Set the chosen subtrees aside instead of deleting them: if the scan
        // fails or stalls, the previous list is put back untouched.
        let displaced = items.filter { item in
            paths.contains { item.folderPath == $0 || item.folderPath.hasPrefix($0 + "/") }
        }
        items.removeAll { item in
            paths.contains { item.folderPath == $0 || item.folderPath.hasPrefix($0 + "/") }
        }

        Task.detached(priority: .userInitiated) {
            let scanner = Scanner(client: nasClient)
            do {
                _ = try scanner.scanIncremental(
                    subtrees: unique.map { (id: $0.id, path: $0.path) },
                    onDiscovery: { found in
                        DispatchQueue.main.async { self.scanStatus = "第 1/2 步：发现目录… 已找到 \(found) 个" }
                    },
                    onFolders: { entries in
                        DispatchQueue.main.async {
                            self.folderEntries = self.folderEntries + entries
                        }
                    },
                    onBatch: { batch in
                        DispatchQueue.main.async {
                            self.pendingScanItems.append(contentsOf: batch)
                            self.scheduleScanFlush()
                        }
                    },
                    onProgress: { done, total in
                        DispatchQueue.main.async {
                            self.scanStatus = "第 2/2 步：读取文件… \(done)/\(total) 个目录"
                        }
                    })

                await MainActor.run {
                    if !self.pendingScanItems.isEmpty {
                        self.items.append(contentsOf: self.pendingScanItems)
                        self.pendingScanItems.removeAll()
                    }
                    var seen = Set<Int>()
                    self.items = self.items.filter { seen.insert($0.id).inserted }.sorted { $0.id < $1.id }
                    self.folderEntries = Dictionary(grouping: self.folderEntries, by: \.path)
                        .compactMap { $0.value.first }
                    self.scannedRoots = Dictionary(grouping: self.scannedRoots + unique, by: \.path)
                        .compactMap { $0.value.first }
                    self.phase = .idle
                    self.scanStatus = nil
                    self.rebuildFolderTree()
                    // The item list was just replaced: every cached aggregate
                    // must be recomputed before the UI reads it again.
                    self.invalidateCounts()
                    self.reconcileDoneWithScan(key: key)
                    AppState.appendRunLog("扫描完成：#\(unique.count) 个目录，共 \(self.items.count) 项")
                    self.invalidateCounts()
                    self.statsDirty = true
                    self.folderTreeDirty = true
                    self.banner = "扫描完成：共 \(self.items.count) 项"
                    InventoryStore.save(Inventory(items: self.items,
                                                  folders: self.folderEntries,
                                                  scannedRoots: self.scannedRoots),
                                        key: key)
                    self.lastScopeScanAt = Date()
                    self.lastScopeScanPaths = Set(unique.map(\.path))
                    self.lastScopeNewest = Scanner(client: nasClient).newestItemTime()
                    self.saveScanState(key: key)
                    completion?()
                }
            } catch {
                await MainActor.run {
                    // Restore what we set aside so a failed scan never loses items.
                    var seen = Set(self.items.map(\.id))
                    for item in displaced where seen.insert(item.id).inserted {
                        self.items.append(item)
                    }
                    self.items.sort { $0.id < $1.id }
                    self.pendingScanItems.removeAll()
                    self.phase = .idle
                    self.scanStatus = nil
                    self.invalidateCounts()
                    self.statsDirty = true
                    self.banner = "扫描中断：" + AppState.friendly(error) + "（原有数据已保留）"
                }
            }
        }
    }

    func scan() {
        guard let account, let nasClient, !isBusy else { return }
        phase = .scanning
        banner = nil
        scanStatus = "准备扫描…"
        let key = account.id.uuidString
        Task.detached(priority: .userInitiated) {
            do {
                let scanner = Scanner(client: nasClient)
                var first = true
                var collected: [PhotoItem] = []

                let scanned = try scanner.scanIncremental(
                    onDiscovery: { found in
                        DispatchQueue.main.async {
                            self.scanStatus = "第 1/2 步：发现目录… 已找到 \(found) 个"
                        }
                    },
                    onFolders: { entries in
                        DispatchQueue.main.async { self.folderEntries = entries }
                    },
                    onBatch: { batch in
                        DispatchQueue.main.async {
                            // First batch replaces the cached snapshot.
                            if first { first = false; self.items = [] }
                            self.pendingScanItems.append(contentsOf: batch)
                            self.scheduleScanFlush()
                        }
                    },
                    onProgress: { done, total in
                        DispatchQueue.main.async {
                            self.scanStatus = "第 2/2 步：读取文件… \(done) 个目录 · \(total) 项"
                        }
                    })
                collected = scanned
                await MainActor.run {
                    self.items = collected.sorted { $0.id < $1.id }
                    self.invalidateCounts()
                    self.invalidateQueueRows()
                    self.statsDirty = true
                    self.phase = .idle
                    self.scanStatus = nil
                    self.thumbnailStore.resetFailures()
                    self.banner = "扫描完成：\(collected.count) 项，缺失 \(collected.filter { $0.state != .ready }.count)"
                    self.rebuildFolderTree()
                    InventoryStore.save(Inventory(items: self.items, folders: self.folderEntries),
                                        key: key)
                }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.scanStatus = nil
                    self.banner = "扫描失败：" + AppState.friendly(error)
                }
            }
        }
    }

    /// 开始 always refreshes the ticked folders first, so files uploaded since
    /// the last scan are picked up instead of being silently ignored.
    func refreshThenStart() {
        guard !isBusy else { return }
        let known = rootFolders + scannedRoots + folderEntries
        let chosen = selectedPaths.compactMap { path in known.first { $0.path == path } }
        guard !chosen.isEmpty else {
            banner = "先在左侧勾选要处理的文件夹"
            return
        }

        guard let client = nasClient else { return }
        let wanted = Set(chosen.map(\.path))
        // Scanned a moment ago with the same selection: go straight to work.
        if let last = lastScopeScanAt, Date().timeIntervalSince(last) < 60,
           wanted.isSubset(of: lastScopeScanPaths) {
            start()
            return
        }

        // One cheap request decides whether a refresh scan is needed at all.
        banner = "检查是否有新文件…"
        let baselineNewest = lastScopeNewest
        let sameScope = wanted == lastScopeScanPaths
        Task.detached(priority: .userInitiated) {
            let newest = Scanner(client: client).newestItemTime()
            let fresh = (newest == nil || baselineNewest == nil || !sameScope)
                ? true
                : (newest! > baselineNewest!)
            await MainActor.run {
                if fresh {
                    self.banner = "正在刷新所选目录…"
                    self.scanSelected(roots: chosen) { [weak self] in
                        guard let self else { return }
                        if self.scopeItems.isEmpty {
                            self.banner = "所选目录里没有文件"
                            return
                        }
                        self.start()
                    }
                } else {
                    self.start()
                }
            }
        }
    }


    func start() {
        if DemoMode.isOn { banner = "演示模式：不会连接 NAS"; return }
        AppState.appendRunLog("start(): account=\(account != nil) client=\(nasClient != nil) busy=\(isBusy) items=\(items.count)")
        guard let account, let nasClient, !isBusy else { return }
        let scopeForRun = scopeItems
        guard !scopeForRun.isEmpty else {
            banner = "先在左侧勾选要处理的文件夹（再点「扫描所选」）"
            return
        }
        runScopePaths = selectedPaths
        runScopeBaseline = scopeForRun.reduce(into: 0) { $0 += (isReady($1) ? 0 : 1) }
        phase = .running
        startedAt = Date()
        readyAtStart = jobs.values.filter { $0.stage == .done }.count
        runBaseline = (items.count, items.filter { isReady($0) }.count)
        if let at = lastScopeScanAt, Date().timeIntervalSince(at) > 24 * 3600 {
            banner = "当前使用的是 \(Int(Date().timeIntervalSince(at) / 3600)) 小时前的扫描结果；有新增文件请先点「扫描所选」"
        } else {
            banner = nil
        }
        let engine = Engine(client: nasClient, options: options,
                            storageKey: account.id.uuidString)
        engine.onLog = { line in
            AppState.appendRunLog(line)
            DispatchQueue.main.async {
                self.log.append(line)
                if self.log.count > 500 { self.log.removeFirst(100) }
            }
        }
        // Only the ticked folders may enter the queue.
        let snapshotItems = scopeForRun
        engine.onUpdate = { job in
            DispatchQueue.main.async { self.enqueue(job) }
        }
        engine.onProgress = { id, fraction in
            DispatchQueue.main.async {
                self.pendingProgress[id] = fraction
                self.scheduleFlush()
            }
        }
        self.engine = engine
        Task.detached(priority: .userInitiated) {
            do {
                try engine.loadQueue(items: snapshotItems)
                // Progress denominator must be the queue we actually built,
                // not a snapshot taken before the refresh scan.
                let workCount = engine.jobs.filter { $0.stage != .done }.count
                let settled = engine.settledItemIDs
                await MainActor.run {
                    self.runScopeBaseline = workCount
                    // The NAS already has these (a previous run finished them);
                    // reflect that locally instead of showing them as missing.
                    if !settled.isEmpty {
                        let ids = Set(settled)
                        self.items = self.items.map { item in
                            guard ids.contains(item.id), item.state != .ready else { return item }
                            var copy = item
                            copy.state = .ready
                            copy.sizeStates = ["sm": "ready", "m": "ready", "xl": "ready"]
                            return copy
                        }
                        self.invalidateCounts()
                        self.statsDirty = true
                        self.folderTreeDirty = true
                    }
                }
                await MainActor.run {
                    var map: [Int: Job] = [:]
                    for job in engine.jobs { map[job.id] = job }
                    self.jobs = map
                }
            } catch {
                await MainActor.run {
                    self.phase = .idle
                    self.banner = "无法建立队列：" + AppState.friendly(error)
                }
                return
            }
            await self.runEngineOffPool(engine)
            await MainActor.run {
                self.phase = .finished
                if let stop = engine.lastStopReason {
                    self.banner = stop
                }
                if let key = self.account?.id.uuidString {
                    self.saveDoneList(key: key)
                    self.reloadLedger(key: key)
                    InventoryStore.save(Inventory(items: self.items,
                                                  folders: self.folderEntries,
                                                  scannedRoots: self.scannedRoots),
                                        key: key)
                }
                var map: [Int: Job] = [:]
                for job in engine.jobs { map[job.id] = job }
                self.jobs = map
                self.rebuildFolderTree()
                self.banner = "完成：成功 \(engine.summary.done)，失败 \(engine.summary.failed)"
                // No automatic rescan: item state is updated as jobs finish,
                // and re-walking a 74k-item folder looked like a loop.
            }
        }
    }

    /// Re-process a single item (usually a failed one).
    func retry(itemID: Int) {
        guard let account, let nasClient, !isBusy else { return }
        phase = .running
        startedAt = Date()
        readyAtStart = jobs.values.filter { $0.stage == .done }.count
        runBaseline = (items.count, items.filter { isReady($0) }.count)
        banner = "重试 1 项…"
        let engine = Engine(client: nasClient, options: options,
                            storageKey: account.id.uuidString)
        engine.onlyItemIDs = [itemID]
        engine.onLog = { line in
            AppState.appendRunLog(line)
            DispatchQueue.main.async {
                self.log.append(line)
                if self.log.count > 500 { self.log.removeFirst(100) }
            }
        }
        engine.onUpdate = { job in
            DispatchQueue.main.async { self.enqueue(job) }
        }
        engine.onProgress = { id, fraction in
            DispatchQueue.main.async {
                self.pendingProgress[id] = fraction
                self.scheduleFlush()
            }
        }
        self.engine = engine
        let snapshot = items
        Task.detached(priority: .userInitiated) {
            try? engine.loadQueue(items: snapshot)
            await MainActor.run {
                var map: [Int: Job] = [:]
                for job in engine.jobs { map[job.id] = job }
                self.jobs = map
            }
            await self.runEngineOffPool(engine)
            await MainActor.run {
                self.phase = .finished
                if let key = self.account?.id.uuidString {
                    InventoryStore.save(Inventory(items: self.items,
                                                  folders: self.folderEntries,
                                                  scannedRoots: self.scannedRoots),
                                        key: key)
                }
                var map: [Int: Job] = [:]
                for job in engine.jobs { map[job.id] = job }
                self.jobs = map
                self.rebuildFolderTree()
                self.banner = "重试完成"
                // No automatic rescan: item state is updated as jobs finish,
                // and re-walking a 74k-item folder looked like a loop.
            }
        }
    }

    func retryAllFailed() {
        let failed = items.filter { jobs[$0.id]?.stage == .failed }.map { $0.id }
        guard !failed.isEmpty else { banner = "没有失败项"; return }
        guard let account, let nasClient, !isBusy else { return }
        phase = .running
        startedAt = Date()
        readyAtStart = jobs.values.filter { $0.stage == .done }.count
        runBaseline = (items.count, items.filter { isReady($0) }.count)
        banner = "重试 \(failed.count) 项…"
        let engine = Engine(client: nasClient, options: options,
                            storageKey: account.id.uuidString)
        engine.onlyItemIDs = Set(failed)
        engine.onLog = { line in
            AppState.appendRunLog(line)
            DispatchQueue.main.async {
                self.log.append(line)
                if self.log.count > 500 { self.log.removeFirst(100) }
            }
        }
        engine.onUpdate = { job in
            DispatchQueue.main.async { self.enqueue(job) }
        }
        engine.onProgress = { id, fraction in
            DispatchQueue.main.async {
                self.pendingProgress[id] = fraction
                self.scheduleFlush()
            }
        }
        self.engine = engine
        let snapshot = items
        Task.detached(priority: .userInitiated) {
            try? engine.loadQueue(items: snapshot)
            await MainActor.run {
                var map: [Int: Job] = [:]
                for job in engine.jobs { map[job.id] = job }
                self.jobs = map
            }
            await self.runEngineOffPool(engine)
            await MainActor.run {
                self.phase = .finished
                if let key = self.account?.id.uuidString {
                    InventoryStore.save(Inventory(items: self.items,
                                                  folders: self.folderEntries,
                                                  scannedRoots: self.scannedRoots),
                                        key: key)
                }
                var map: [Int: Job] = [:]
                for job in engine.jobs { map[job.id] = job }
                self.jobs = map
                self.rebuildFolderTree()
                self.banner = "重试完成"
                // No automatic rescan: item state is updated as jobs finish,
                // and re-walking a 74k-item folder looked like a loop.
            }
        }
    }

    /// Loopback URL that streams the original item, with Range support.
    /// Reuses the same authenticated proxy the thumbnailer uses for ffmpeg.
    func streamURL(for id: Int) -> URL? {
        guard let nasClient else { return nil }
        if mediaProxy == nil {
            let proxy = MediaProxy(backend: NASBackend(client: nasClient, maxSlice: 4 << 20))
            guard let port = try? proxy.start() else { return nil }
            mediaProxy = proxy
            mediaProxyPort = port
        }
        guard let port = mediaProxyPort else { return nil }
        return URL(string: "http://127.0.0.1:\(port)/unit/\(id)")
    }

    /// AVPlayer fed straight from the NAS through a resource loader.
    /// HTTP proxying does not work here: AVFoundation rejects partial answers
    /// to open-ended ranges ("content range mismatch").
    func makePlayer(for id: Int) -> AVPlayer? {
        guard let nasClient else { return nil }
        let loader = mediaLoader ?? NASMediaLoader(client: nasClient)
        mediaLoader = loader
        let asset = AVURLAsset(url: NASMediaLoader.url(for: id))
        // Dedicated queue: main can be busy rendering the grid.
        asset.resourceLoader.setDelegate(loader, queue: playerQueue)
        return AVPlayer(playerItem: AVPlayerItem(asset: asset))
    }

    func openViewer(_ id: Int) {
        viewingItemID = id
    }

    private func enqueue(_ job: Job) {
        pendingJobs[job.id] = job
        if job.stage != .fetching { pendingClears.insert(job.id) }
        if job.stage == .done {
            ledgerStages[job.id] = .done
            doneItems.insert(job.id)
        }
        if job.stage == .done, let idx = items.firstIndex(where: { $0.id == job.id }) {
            thumbnailStore.refresh(items[idx])
            // Apply to `items` in batches: one copy per second instead of one
            // per completion, but the grid and the counters stay in sync.
            pendingReadyIDs.insert(job.id)
            scheduleReadyFlush()
        }
        scheduleFlush()
    }

    /// Coalesces scan batches: publishing 1,000+ times would re-filter 160k
    /// items on every publish and freeze the window.
    private func scheduleReadyFlush() {
        guard !readyFlushScheduled else { return }
        readyFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.readyFlushScheduled = false
            guard !self.pendingReadyIDs.isEmpty else { return }
            let ready = self.pendingReadyIDs
            self.pendingReadyIDs.removeAll()
            self.items = self.items.map { item in
                guard ready.contains(item.id), item.state != .ready else { return item }
                var copy = item
                copy.state = .ready
                // The server now serves all three sizes; keep the per-size
                // verdict in sync so the inspector stops saying 缺 xl/m/sm.
                copy.sizeStates = ["sm": "ready", "m": "ready", "xl": "ready"]
                return copy
            }
            self.invalidateCounts()
            self.statsDirty = true
            // Folder counts must follow completed items, not just rescans.
            self.folderTreeDirty = true
        }
    }

    private func scheduleScanFlush() {
        guard !scanFlushScheduled else { return }
        scanFlushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            self.scanFlushScheduled = false
            guard !self.pendingScanItems.isEmpty else { return }
            let batch = self.pendingScanItems
            self.pendingScanItems.removeAll(keepingCapacity: true)
            var seen = Set(self.items.map(\.id))
            for item in batch where seen.insert(item.id).inserted {
                self.items.append(item)
            }
        }
    }

    private func scheduleFlush() {
        queueVersion &+= 1
        queueRowsDirty = true
        countsDirty = true
        statsDirty = true
        guard !flushScheduled else { return }
        flushScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            self.flushScheduled = false
            if !self.pendingJobs.isEmpty {
                for (id, job) in self.pendingJobs { self.jobs[id] = job }
                self.pendingJobs.removeAll()
            }
            if !self.pendingProgress.isEmpty {
                for (id, value) in self.pendingProgress { self.liveProgress[id] = value }
                self.pendingProgress.removeAll()
            }
            if !self.pendingClears.isEmpty {
                for id in self.pendingClears { self.liveProgress[id] = nil }
                self.pendingClears.removeAll()
            }
        }
    }

    nonisolated static func appendRunLog(_ line: String) {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SIA-Lite", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("run.log")
        let stamp = ISO8601DateFormatter().string(from: Date())
        guard let data = "\(stamp) \(line)\n".data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: url)
        }
    }

    func pause() {
        engine?.pause()
        phase = .paused
    }

    func resume() {
        engine?.resume()
        phase = .running
    }

    func stop() {
        engine?.cancel()
        engine = nil
        if phase == .running || phase == .paused { phase = .idle }
    }
}
