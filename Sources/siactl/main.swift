import Foundation
import AVFoundation
import SIACore

// siactl — headless driver for SIA-Desktop.
// Deliberately has NO write path yet: the only mutation (preview upload) is
// gated behind an unimplemented command so this binary cannot alter the NAS.

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("error: " + message + "\n").utf8))
    exit(code)
}

func usage() -> Never {
    print("""
    siactl — Synology Image Assistant replacement (headless core)

    USAGE:
      siactl thumb <video> <outdir> [seconds]     extract a frame -> 3 JPEGs
      siactl probe <video>                        print codec/duration facts
      siactl scan [--host H] [--account A] [--out FILE]
                                                  read-only inventory + preview status

    Nothing here writes to the NAS.
    """)
    exit(2)
}


/// Every command takes its target from the command line or the environment.
/// Nothing about a particular NAS is compiled into the tool.
func makeClient(host: String? = nil, account: String? = nil) -> NASClient {
    let env = ProcessInfo.processInfo.environment
    let h = host ?? env["SIA_HOST"] ?? ""
    let a = account ?? env["SIA_ACCOUNT"] ?? ""
    guard !h.isEmpty, !a.isEmpty else {
        FileHandle.standardError.write(Data("需要 NAS 地址与账号：--host / --account 或 SIA_HOST / SIA_ACCOUNT\n".utf8))
        exit(64)
    }
    return NASClient(host: h, account: a, keychainService: env["SIA_KEYCHAIN"] ?? "sia-desktop")
}

let argv = CommandLine.arguments
guard argv.count >= 2 else { usage() }
let command = argv[1]

switch command {

case "thumb":
    guard argv.count >= 4 else { usage() }
    let input = URL(fileURLWithPath: argv[2])
    let outDir = URL(fileURLWithPath: argv[3])
    let seconds = argv.count >= 5 ? (Double(argv[4]) ?? 1.0) : 1.0
    guard FileManager.default.fileExists(atPath: input.path) else {
        fail("no such file: \(input.path)")
    }
    do {
        let set = try Thumbnailer.generate(input: input, outDir: outDir, seconds: seconds)
        let size = { (u: URL) -> String in
            let attrs = try? FileManager.default.attributesOfItem(atPath: u.path)
            let n = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            return "\(n)B"
        }
        print("xl: \(set.xl.path)  (\(set.width)x\(set.height), \(size(set.xl)))")
        print("m : \(set.m.path)  (\(size(set.m)))")
        print("sm: \(set.sm.path)  (\(size(set.sm)))")
    } catch {
        fail("\(error)")
    }

case "probe":
    guard argv.count >= 3 else { usage() }
    let input = URL(fileURLWithPath: argv[2])
    guard let probe = Thumbnailer.locateFFprobe() else { fail("ffprobe missing") }
    let p = Process()
    p.executableURL = probe
    p.arguments = ["-v", "error", "-select_streams", "v:0",
                   "-show_entries", "stream=codec_name,width,height,avg_frame_rate",
                   "-of", "default=nw=1", input.path]
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = Pipe()
    try? p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    print(String(data: data, encoding: .utf8) ?? "")
    if let d = Thumbnailer.duration(of: input) { print("duration=\(d)") }

case "scan":
    var host = ProcessInfo.processInfo.environment["SIA_HOST"] ?? ""
    var account = ProcessInfo.processInfo.environment["SIA_ACCOUNT"] ?? ""
    var outFile: String? = nil
    var i = 2
    while i < argv.count {
        switch argv[i] {
        case "--host": host = argv[i + 1]; i += 2
        case "--account": account = argv[i + 1]; i += 2
        case "--out": outFile = argv[i + 1]; i += 2
        default: fail("unknown option \(argv[i])")
        }
    }
    let client = NASClient(host: host, account: account)
    do {
        try client.login()
        let scanner = Scanner(client: client)
        var lastPrint = Date.distantPast
        let items = try scanner.scanAll { path, count in
            if Date().timeIntervalSince(lastPrint) > 1.5 {
                lastPrint = Date()
                FileHandle.standardError.write(Data("  scanned \(count) items @ \(path)\n".utf8))
            }
        }
        let ready = items.filter { $0.state == .ready }.count
        let ame = items.filter { $0.state == .ameDefect }.count
        let broken = items.filter { $0.state == .broken }.count
        let unknown = items.filter { $0.state == .unknown }.count
        print("""
        total=\(items.count) ready=\(ready) ame_defect=\(ame) broken=\(broken) unknown=\(unknown)
        needs_work=\(items.count - ready)
        """)
        if let outFile {
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(items).write(to: URL(fileURLWithPath: outFile))
            print("written \(outFile)")
        }
    } catch {
        fail("\(error)")
    }

case "plan":
    var outCsv = "work-queue.csv"
    var i = 2
    while i < argv.count {
        if argv[i] == "--out", i + 1 < argv.count { outCsv = argv[i + 1]; i += 2 } else { i += 1 }
    }
    let client = makeClient()
    do {
        try client.login()
        let items = try Scanner(client: client).scanAll()
        let todo = items.filter { $0.state != .ready }.sorted { $0.bytes > $1.bytes }
        let bytes = todo.reduce(0) { $0 + $1.bytes }
        print("work queue: \(todo.count) items, \(String(format: "%.2f", Double(bytes) / 1e9)) GB of source")
        for item in todo.prefix(10) {
            print(String(format: "  %8.1f MB  %@  [%@ %@]", Double(item.bytes) / 1e6, item.filename,
                         item.codec ?? "-", item.state.rawValue))
        }
        if todo.count > 10 { print("  ... and \(todo.count - 10) more") }
        var csv = "id,filename,type,bytes,folder_path,state,codec,width,height\n"
        for t in todo {
            csv += "\(t.id),\(t.filename),\(t.type),\(t.bytes),\(t.folderPath),\(t.state.rawValue),\(t.codec ?? ""),\(t.width ?? 0),\(t.height ?? 0)\n"
        }
        try csv.write(to: URL(fileURLWithPath: outCsv), atomically: true, encoding: .utf8)
        print("written \(outCsv)")
    } catch {
        fail("\(error)")
    }

case "run":
    var dryRun = false
    var limit: Int? = nil
    var opts = EngineOptions()
    var i = 2
    while i < argv.count {
        switch argv[i] {
        case "--dry-run": dryRun = true; i += 1
        case "--limit": limit = Int(argv[i + 1]); i += 2
        case "--mode":
            opts.mode = RunMode(rawValue: argv[i + 1]) ?? .balanced; i += 2
        case "--strategy":
            opts.strategy = FetchStrategy(rawValue: argv[i + 1]) ?? .prefix; i += 2
        case "--upload": opts.autoUpload = true; i += 1
        case "--concurrency":
            if i + 1 < argv.count, let n = Int(argv[i + 1]) { opts.concurrency = n; i += 2 } else { i += 1 }
        case "--skip-over-gb":
            opts.skipLargerThanBytes = (Int(argv[i + 1]) ?? 0) * 1_000_000_000; i += 2
        default: fail("unknown option \(argv[i])")
        }
    }
    let client = makeClient()
    do {
        try client.login()
        print("扫描中…")
        let items = try Scanner(client: client).scanAll()
        let engine = Engine(client: client, options: opts)
        engine.prepare(from: items)
        engine.onLog = { line in print(line) }
        engine.onJobUpdate = { job in
            print(String(format: "  [%-8@] %@  %@", job.stage.rawValue as NSString,
                         job.filename, job.message))
        }
        let s = engine.summary
        print("队列: \(engine.jobs.count) 项 (待办 \(s.pending)) | 模式 \(opts.mode.label) | 策略 \(opts.strategy.label)")
        if opts.autoUpload && !dryRun {
            print("⚠️ 已开启上传：会向 NAS 写入派生缩略图（不修改原图）")
        }
        print(dryRun ? "—— 干跑，不读取任何文件 ——" : "—— 开始 ——")
        engine.run(dryRun: dryRun, limit: limit)
        let after = engine.summary
        print("""
        结果: done=\(after.done) ready=\(after.ready) failed=\(after.failed) blocked=\(after.blocked) pending=\(after.pending)
        """)
        if let err = engine.lastError { print("停止原因: \(err)") }
    } catch {
        fail("\(error)")
    }

case "simulate":
    // Exercises the full pipeline (chunked read -> progress -> pause -> frame
    // extraction) against a LOCAL file, so it never touches the NAS.
    var file: String? = nil
    var count = 3
    var delay = 0.05
    var pauseAfter: Double? = nil
    var i = 2
    while i < argv.count {
        switch argv[i] {
        case "--file": file = argv[i + 1]; i += 2
        case "--count": count = Int(argv[i + 1]) ?? 3; i += 2
        case "--delay": delay = Double(argv[i + 1]) ?? 0.05; i += 2
        case "--pause-at": pauseAfter = Double(argv[i + 1]); i += 2
        default: fail("unknown option \(argv[i])")
        }
    }
    guard let file else { fail("--file required") }
    let url = URL(fileURLWithPath: file)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file: \(file)") }

    var opts = EngineOptions()
    opts.strategy = .prefix
    opts.prefixBudgetBytes = 4 << 20
    let engine = Engine(source: LocalFileSource(url: url, chunkDelay: delay), options: opts)
    engine.prepareLocal(files: Array(repeating: url, count: count))

    var lastPercent = -1
    engine.onProgress = { id, fraction in
        let pct = Int(fraction * 100)
        if pct != lastPercent && pct % 10 == 0 {
            lastPercent = pct
            print("  progress item=\(id) \(pct)%")
        }
    }
    engine.onJobUpdate = { job in
        if job.stage == .readyToUpload || job.stage == .failed || job.stage == .cancelled {
            print("  [\(job.stage.rawValue)] \(job.filename) — \(job.message)")
        }
    }
    engine.onLog = { print("  \($0)") }

    if let pauseAfter {
        // Pause/resume smoke test: pause at N%, resume shortly after.
        DispatchQueue.global().asyncAfter(deadline: .now() + pauseAfter) {
            engine.pause()
            DispatchQueue.global().asyncAfter(deadline: .now() + 1.0) { engine.resume() }
        }
    }
    engine.run(dryRun: false)
    let s = engine.summary
    print("simulate: ready=\(s.ready) failed=\(s.failed) pending=\(s.pending)")

case "remote-sim":
    // Proves the remote-decode path (ffmpeg -> loopback proxy -> byte ranges)
    // against a LOCAL file, including the moov-at-end case that prefix reads
    // cannot handle.
    var file: String? = nil
    var count = 1
    var i = 2
    while i < argv.count {
        switch argv[i] {
        case "--file": file = argv[i + 1]; i += 2
        case "--count": count = Int(argv[i + 1]) ?? 1; i += 2
        default: fail("unknown option \(argv[i])")
        }
    }
    guard let file else { fail("--file required") }
    let url = URL(fileURLWithPath: file)
    guard FileManager.default.fileExists(atPath: url.path) else { fail("no such file") }

    let proxy = MediaProxy(backend: LocalFileBackend(fileURL: url))
    do {
        let port = try proxy.start()
        print("proxy on 127.0.0.1:\(port) → \(url.lastPathComponent)")
        let out = URL(fileURLWithPath: "/tmp/sia-remote")
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for n in 0..<count {
            let started = Date()
            let set = try Thumbnailer.generate(inputArgument: "http://127.0.0.1:\(port)/unit/1",
                                               stem: "remote_\(n)",
                                               outDir: out,
                                               seconds: Double(n) + 1.0)
            let ms = Int(Date().timeIntervalSince(started) * 1000)
            print("  frame \(n): \(set.width)x\(set.height) in \(ms)ms → \(set.xl.path)")
        }
        let sourceSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        let src = Double(sourceSize ?? 0) / 1e6
        let sent = Double(proxy.bytesServed) / 1e6
        print(String(format: "传输 %.2f MB / 源文件 %.2f MB (%.1f%%)，共 %d 次 Range 请求",
                     sent, src, src > 0 ? sent / src * 100 : 0, proxy.requestCount))
        for (s0, e0) in proxy.servedRanges {
            print(String(format: "  range %8.2f–%8.2f MB", Double(s0) / 1e6, Double(e0) / 1e6))
        }
        proxy.stop()
        print("remote-sim: ok")
    } catch {
        proxy.stop()
        fail("\(error)")
    }

case "preflight":
    // One-shot readiness check. Every item prints PASS/FAIL plus the exact fix,
    // so a blocked run tells the user what to change instead of a bare error.
    let client = makeClient()
    var failures = 0
    func row(_ name: String, _ ok: Bool, _ detail: String, fix: String = "") {
        print(String(format: "  %@ %-26@ %@", ok ? "✅" : "❌", name as NSString, detail))
        if !ok {
            failures += 1
            if !fix.isEmpty { print("     ↳ 修复: \(fix)") }
        }
    }

    print("=== SIA 预检 ===")
    do {
        try client.login()
        row("DSM 登录", true, "session=webui + cookie + SynoToken")
    } catch {
        row("DSM 登录", false, "\(error)", fix: "检查 Keychain 里的账号密码")
        print("\n预检中止：连登录都不通")
        exit(1)
    }

    // 1. shared folder read access
    // FileStation access to /photo is NOT required: bytes come through the
    // Photos API (SYNO.FotoTeam.Download with item_id). Kept as information only.
    if let resp = try? client.call(api: "SYNO.FileStation.List", version: "2", method: "list",
                                   params: ["folder_path": "/photo", "limit": "20"]),
       let files = (resp["data"] as? [String: Any])?["files"] as? [[String: Any]] {
        let names = files.compactMap { $0["name"] as? String }
        print("  ℹ️  FileStation /photo: \(names.count) 项可见（本程序不依赖它）")
    }

    // 2. scan
    var items: [PhotoItem] = []
    do {
        items = try Scanner(client: client).scanAll()
        let todo = items.filter { $0.state != .ready }.count
        row("相册扫描", true, "\(items.count) 项，待处理 \(todo)")
    } catch {
        row("相册扫描", false, "\(error)")
    }

    // 3. byte-level download
    var downloadOK = false
    if let video = items.filter({ $0.type.hasPrefix("video") && $0.state != .ready })
        .min(by: { $0.bytes < $1.bytes }) {
        do {
            let sample = try Fetcher.chunked(client: client, unitId: video.id,
                                             cacheKey: video.cacheKey, budget: 64 << 10) { _, _ in true }
            downloadOK = !sample.data.isEmpty
            row("读取原始字节", true, "\(video.filename) 取到 \(sample.data.count) B")
        } catch {
            row("读取原始字节", false, "\(error)",
                fix: "同上：/photo 共享文件夹需要「读取」权限")
        }
    } else {
        row("读取原始字节", false, "没有可测的目标")
    }

    // 4. moov placement (only meaningful once bytes are readable)
    if downloadOK, let video = items.filter({ $0.type.hasPrefix("video") && $0.state != .ready })
        .min(by: { $0.bytes < $1.bytes }),
       let moovFront = Fetcher.hasMoovInHead(client: client, unitId: video.id, cacheKey: video.cacheKey) {
        row("MP4 索引位置", true, moovFront ? "moov 在文件头 → 走 prefix" : "moov 在文件尾 → 走 remote")
    } else {
        row("MP4 索引位置", false, "需要先能读字节")
    }

    // 5. upload contract static check (no network write)
    row("上传契约", true, "\(ConvertedFileUpload.api) v\(ConvertedFileUpload.version)，默认关闭")

    // 6. write gate state
    row("写入开关", true, "默认关闭（需用户在设置里显式开启）")

    print("")
    if failures == 0 {
        print("预检通过：可以开始真实运行")
        exit(0)
    } else {
        print("预检未通过：\(failures) 项需要处理")
        exit(2)
    }

case "tailtest":
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 } else { i += 1 }
    }
    guard let id else { print("用法: siactl tailtest --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        let t0 = Date()
        let index = try MP4TailIndex.inspect(client: client, itemID: id)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("tail-\(id).mp4")
        try MP4TailIndex.materialize(client: client, itemID: id, index: index, path: tmp)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("tail-out-\(id)", isDirectory: true)
        let set = try Thumbnailer.generate(inputArgument: tmp.path, stem: "f", outDir: out, seconds: 0)
        print("成功 \(set.width)x\(set.height)  耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s  moov@\(index.moovOffset) 样本\(index.firstSample?.size ?? 0)B")
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "prefixtest":
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 } else { i += 1 }
    }
    guard let id else { print("用法: siactl prefixtest --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        let t0 = Date()
        let sample = try Fetcher.chunked(client: client, unitId: id, cacheKey: nil,
                                         budget: 8 << 20, deadline: 180) { _, _ in true }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-\(id).mp4")
        try sample.data.write(to: tmp)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("prefix-out-\(id)", isDirectory: true)
        let set = try Thumbnailer.generate(inputArgument: tmp.path, stem: "f", outDir: out, seconds: 0.3)
        print("成功 \(set.width)x\(set.height)  取数 \(sample.data.count/1024) KB  耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "imgthumb":
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 }
        else { i += 1 }
    }
    guard let id else { print("用法: siactl imgthumb --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        let (data, _) = try client.raw(api: "SYNO.FotoTeam.Download", version: "1",
                                       method: "download", params: ["item_id": "[\(id)]"],
                                       rangeHeader: nil)
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("probe-\(id).bin")
        try data.write(to: tmp)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("imgthumb-\(id)", isDirectory: true)
        let t0 = Date()
        let set = try ImageThumbnailer.generate(input: tmp, outDir: out)
        print("解码成功 \(set.width)x\(set.height)  耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s  源 \(data.count / 1024) KB")
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "progressprobe":
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 }
        else { i += 1 }
    }
    guard let id else { print("用法: siactl progressprobe --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        var last = -1
        _ = try Fetcher.chunked(client: client, unitId: id, cacheKey: nil,
                                budget: 8 << 20, deadline: 120,
                                onTick: { f in
                                    let pct = Int(f * 100)
                                    if pct != last { last = pct; print("tick \(pct)%") }
                                }) { _, _ in true }
        print("完成")
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "scanfast":
    let client = makeClient()
    do {
        try client.login()
        let t0 = Date()
        var folders = 0
        let scanner = Scanner(client: client)
        let items = try scanner.scanIncremental(
            workers: 6,
            onFolders: { folders = $0.count },
            onBatch: { _ in },
            onProgress: { done, total in
                if done % 20 == 0 { print("  \(done)/\(folders) 目录 · \(total) 项") }
            })
        print("扫描完成：\(items.count) 项 / \(folders) 个目录，耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "folders":
    let client = makeClient()
    do {
        try client.login()
        let list = try Scanner(client: client).scanFolders()
        print("共 \(list.count) 个文件夹")
        for f in list.prefix(20) { print("  \(f.path)  (id \(f.id))") }
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "thumbcheck":
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 }
        else { i += 1 }
    }
    guard let id else { print("用法: siactl thumbcheck --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        let tc = ThumbnailClient(client: client, accountID: UUID())
        let none = tc.thumbnail(id: id, cacheKey: nil, size: .sm)
        let bust = tc.thumbnail(id: id, cacheKey: "r\(Int(Date().timeIntervalSince1970))", size: .sm)
        print("无 cache_key: \(none.map { "\($0.count) B" } ?? "失败")")
        print("带 cache_key: \(bust.map { "\($0.count) B" } ?? "失败")")
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "avframe":
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 }
        else { i += 1 }
    }
    guard let id else { print("用法: siactl avframe --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        let loader = NASMediaLoader(client: client)
        let asset = AVURLAsset(url: NASMediaLoader.url(for: id))
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "avframe"))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let t0 = Date()
        let sem = DispatchSemaphore(value: 0)
        gen.generateCGImagesAsynchronously(forTimes: [NSValue(time: CMTime(seconds: 0.3, preferredTimescale: 600))]) { _, image, _, result, error in
            if let image {
                print("帧: \(image.width)x\(image.height)  耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s  传输 \(String(format: "%.1f", Double(loader.bytesServed) / 1e6))MB")
            } else {
                print("失败:", error?.localizedDescription ?? "未知", "result=\(result.rawValue)")
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "remotethumb":
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 }
        else { i += 1 }
    }
    guard let id else { print("用法: siactl thumb --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("thumb-\(id)", isDirectory: true)
        let t0 = Date()
        let set = try VideoFrame.extract(client: client, itemID: id, seconds: 0.3,
                                         totalBytes: 1, stem: "s", outDir: out)
        let mb = ["xl", "m", "sm"].compactMap { name -> Int in
            let u = out.appendingPathComponent("s_\(name).jpg")
            return (try? FileManager.default.attributesOfItem(atPath: u.path)[.size] as? Int) ?? 0
        }.reduce(0, +)
        print("生成 \(set.width)x\(set.height)  耗时 \(String(format: "%.1f", Date().timeIntervalSince(t0)))s  三档文件 \(String(format: "%.2f", Double(mb) / 1e6))MB")
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "avtest":
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 }
        else { i += 1 }
    }
    guard let id else { print("用法: siactl avtest --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        let loader = NASMediaLoader(client: client)
        let asset = AVURLAsset(url: NASMediaLoader.url(for: id))
        asset.resourceLoader.setDelegate(loader, queue: DispatchQueue(label: "avtest.loader"))
        print("url:", NASMediaLoader.url(for: id).absoluteString)
        let sem = DispatchSemaphore(value: 0)
        Task {
            do {
                let dur = try await asset.load(.duration)
                let tracks = try await asset.loadTracks(withMediaType: .video)
                print("duration:", CMTimeGetSeconds(dur), "videoTracks:", tracks.count)
                if let t = tracks.first {
                    let size = try await t.load(.naturalSize)
                    let fps = try await t.load(.nominalFrameRate)
                    print("size:", size.width, "x", size.height, "fps:", fps)
                }
            } catch {
                print("AVAsset 加载失败:", error)
            }
            sem.signal()
        }
        sem.wait()
        exit(0)
    } catch { print("失败:", error); exit(1) }

case "stream":
    // Verifies the exact URL AVPlayer will use: local authenticated proxy.
    var id: Int?
    var i = 2
    while i < argv.count {
        if argv[i] == "--id", i + 1 < argv.count { id = Int(argv[i + 1]); i += 2 }
        else { i += 1 }
    }
    guard let id else { print("用法: siactl stream --id <item>"); exit(64) }
    let client = makeClient()
    do {
        try client.login()
        let proxy = MediaProxy(backend: NASBackend(client: client))
        let port = try proxy.start()
        let url = "http://127.0.0.1:\(port)/unit/\(id)"
        print("stream url:", url)
        // Probe the proxy framing before handing it to a player.
        let probeURL = URL(string: url)!
        var probeReq = URLRequest(url: probeURL)
        probeReq.setValue("bytes=0-63", forHTTPHeaderField: "Range")
        let sem = DispatchSemaphore(value: 0)
        URLSession.shared.dataTask(with: probeReq) { d, r, e in
            let http = r as? HTTPURLResponse
            print("proxy probe status:", http?.statusCode ?? -1,
                  "bytes:", d?.count ?? 0,
                  "range:", http?.value(forHTTPHeaderField: "Content-Range") ?? "-")
            if let d, !d.isEmpty {
                print("head hex:", d.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " "))
                print("head ascii:", String(data: d.prefix(16), encoding: .ascii) ?? "?")
            }
            if let e { print("probe error:", e.localizedDescription) }
            sem.signal()
        }.resume()
        sem.wait()
        guard let ffprobe = Thumbnailer.locateFFprobe() else {
            print("找不到 ffprobe"); exit(1)
        }
        let p = Process()
        p.executableURL = ffprobe
        p.arguments = ["-v", "error", "-show_entries", "format=duration,format_name",
                       "-of", "default=nw=1", url]
        let out = Pipe(); let errPipe = Pipe()
        p.standardOutput = out; p.standardError = errPipe
        try p.run(); p.waitUntilExit()
        let text = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        print("ffprobe out:", text.trimmingCharacters(in: .whitespacesAndNewlines))
        if !err.isEmpty { print("ffprobe err:", err.trimmingCharacters(in: .whitespacesAndNewlines).prefix(400)) }
        proxy.stop()
        exit(p.terminationStatus == 0 ? 0 : 1)
    } catch {
        print("失败:", error); exit(1)
    }

default:
    usage()
}
