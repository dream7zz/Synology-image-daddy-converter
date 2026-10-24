import Foundation
import SIACore

// Self-contained test runner.
// This machine has only the Command Line Tools, which ship neither XCTest nor
// the Testing module, so `swift test` cannot be used here. Instead we assert
// directly and exit non-zero on the first failure.

var failures = 0
var checks = 0

func expect(_ condition: Bool, _ message: String, file: String = #file, line: Int = #line) {
    checks += 1
    if !condition {
        failures += 1
        print("  ✗ \(message)  (\(file):\(line))")
    }
}

func expectThrows<T>(_ body: () throws -> T, _ message: String,
                     matching predicate: (Error) -> Bool = { _ in true }) {
    checks += 1
    do {
        _ = try body()
        failures += 1
        print("  ✗ expected to throw: \(message)")
    } catch {
        if !predicate(error) {
            failures += 1
            print("  ✗ wrong error for \(message): \(error)")
        }
    }
}

// MARK: - Strategy planner

print("StrategyPlanner")
expect(StrategyPlanner.decide(explicit: .prefix, moovInHead: false,
                              bytes: 24_000_000_000, maxFullDownload: 512_000_000,
                              hasClient: true) == .prefix,
       "explicit prefix wins")
expect(StrategyPlanner.decide(explicit: .auto, moovInHead: true,
                              bytes: 24_000_000_000, maxFullDownload: 512_000_000,
                              hasClient: true) == .remote,
       "auto: with a client -> remote (measured 5x cheaper than a full read)")
expect(StrategyPlanner.decide(explicit: .auto, moovInHead: false,
                              bytes: 8_000_000, maxFullDownload: 512_000_000,
                              hasClient: true) == .remote,
       "auto: with a client -> remote even for small files")
expect(StrategyPlanner.decide(explicit: .auto, moovInHead: false,
                              bytes: 24_000_000_000, maxFullDownload: 512_000_000,
                              hasClient: true) == .remote,
       "auto: big tail-index -> remote")
if case .blocked = StrategyPlanner.decide(explicit: .auto, moovInHead: false,
                                          bytes: 24_000_000_000, maxFullDownload: 512_000_000,
                                          hasClient: false) {
    checks += 1
} else {
    checks += 1; failures += 1; print("  ✗ big tail-index without client must block")
}
expect(StrategyPlanner.decide(explicit: .auto, moovInHead: nil,
                              bytes: 8_000_000, maxFullDownload: 512_000_000,
                              hasClient: false) == .fullDownload,
       "auto without client: unknown moov, small -> full download")
expect(StrategyPlanner.decide(explicit: .auto, moovInHead: nil,
                              bytes: 24_000_000_000, maxFullDownload: 512_000_000,
                              hasClient: true) == .remote,
       "auto: unknown moov, big -> remote")
expect(StrategyPlanner.decide(explicit: .auto, moovInHead: true,
                              bytes: 8_000_000, maxFullDownload: 512_000_000,
                              hasClient: false) == .prefix,
       "auto without client: index at front -> prefix")
if case .blocked = StrategyPlanner.decide(explicit: .remote, moovInHead: nil,
                                          bytes: 1, maxFullDownload: 1, hasClient: false) {
    checks += 1
} else {
    checks += 1; failures += 1; print("  ✗ remote without client must block")
}

// MARK: - WriteGate (the safety-critical part)

print("WriteGate")

let tmp = FileManager.default.temporaryDirectory
    .appendingPathComponent("sia-selftest-\(UUID().uuidString)")
try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)

func job() -> Job {
    Job(id: 42, filename: "clip.mp4", bytes: 100, folderPath: "/x/",
        stage: .readyToUpload, message: "", thumbDir: nil, progress: 1, updatedAt: Date())
}

// 1. no thumbnails -> plan must fail
let emptyDir = tmp.appendingPathComponent("empty", isDirectory: true)
try? FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
expectThrows({ try WriteGate().plan(for: job(), thumbDir: emptyDir) },
             "plan without thumbnails")

// 2. three sizes -> plan collects exactly 3 files
let thumbDir = tmp.appendingPathComponent("thumbs", isDirectory: true)
try? FileManager.default.createDirectory(at: thumbDir, withIntermediateDirectories: true)
for name in ["clip_xl.jpg", "clip_m.jpg", "clip_sm.jpg"] {
    try? Data([0xFF, 0xD8, 0xFF]).write(to: thumbDir.appendingPathComponent(name))
}
let gate = WriteGate(mode: .planOnly)
if let plan = try? gate.plan(for: job(), thumbDir: thumbDir) {
    expect(plan.files.count == 3, "plan collects 3 sizes")
    expect(plan.api == WriteGate.allowListedAPI, "plan targets the allow-listed API only")
    expect(plan.itemID == 42, "plan keeps item identity")

    // 3. non-confirmed gate never sends
    expectThrows({ try gate.upload(plan) }, "upload while planOnly") { error in
        if case WriteGateError.modeIsNotConfirmed = error { return true }
        return false
    }
} else {
    checks += 1; failures += 1; print("  ✗ plan should have succeeded")
}

// 4. confirmed gate without a client cannot send anything
let confirmed = WriteGate(mode: .confirmed, client: nil)
if let plan = try? confirmed.plan(for: job(), thumbDir: thumbDir) {
    expectThrows({ try confirmed.upload(plan) }, "upload while confirmed without client") { error in
        if case WriteGateError.notConfigured = error { return true }
        return false
    }
}

// 5. a forged plan pointing at a destructive API must be rejected
let forged = UploadPlan(itemID: 42, api: "SYNO.Foto.Delete",
                        files: [], totalBytes: 0, createdAt: Date())
expectThrows({ try confirmed.upload(forged) }, "forged plan") { error in
    if case WriteGateError.apiBlocked = error { return true }
    return false
}

// MARK: - Recovered upload contract (multipart shape)

print("ConvertedFile upload")
let xlData = Data(repeating: 0x41, count: 16)
let mData = Data(repeating: 0x42, count: 8)
let smData = Data(repeating: 0x43, count: 4)
let upload = ConvertedFileUpload(unitID: 12345, token: "TOK", xl: xlData, m: mData, sm: smData)
let body = upload.body(boundary: "BOUNDARY")
let text = String(data: body.data, encoding: .utf8) ?? ""
expect(body.contentType == "multipart/form-data; boundary=BOUNDARY", "content type carries the boundary")
for field in ["thumb_xl", "thumb_m", "thumb_sm"] {
    expect(text.contains("name=\"\(field)\""), "multipart has \(field) part")
}
expect(text.contains("name=\"unit_id\"\r\n\r\n12345"), "unit_id field present")
expect(text.contains("name=\"api\"\r\n\r\nSYNO.FotoTeam.Upload.ConvertedFile"), "api field present")
expect(text.contains("name=\"method\"\r\n\r\nupload"), "method field present")
expect(text.contains("name=\"token\"\r\n\r\nTOK"), "token field present (matches RB())")
expect(ConvertedFileUpload.version == "3", "version 3, per the client version table")
expect(text.contains("Content-Type: image/jpeg"), "parts declare image/jpeg")
expect(text.hasSuffix("--BOUNDARY--\r\n"), "body terminates with the closing boundary")
expect(body.data.count > xlData.count + mData.count + smData.count, "body carries the file bytes")

// MARK: - Preview classification

print("Preview classification")

func thumb(_ sm: String, _ m: String, _ xl: String) -> [String: Any] {
    ["thumbnail": ["sm": sm, "m": m, "xl": xl]]
}
expect(Scanner.classifyAdditional(thumb("ready", "ready", "ready")).0 == .ready,
       "all ready -> ready")
expect(Scanner.classifyAdditional(thumb("ame_defect", "ame_defect", "ame_defect")).0 == .ameDefect,
       "ame_defect sizes -> ameDefect")
expect(Scanner.classifyAdditional(thumb("broken", "broken", "broken")).0 == .broken,
       "broken sizes -> broken")
// refinement: server says ame_defect even though the sizes read "broken"
var refined = thumb("broken", "broken", "broken")
refined["video_convert_status"] = "ame_defect"
expect(Scanner.classifyAdditional(refined).0 == .ameDefect,
       "video_convert_status ame_defect overrides broken")
expect(Scanner.classifyAdditional([:]).0 == .unknown, "empty -> unknown")
expect(Scanner.classifyAdditional(thumb("ready", "ready", "broken")).0 == .broken,
       "partially ready -> broken (never treated as done)")

// MARK: - Thumbnail spec

print("Thumbnail spec")
let mapping = Dictionary(uniqueKeysWithValues: Thumbnailer.shortEdges.map { ($0.name, $0.edge) })
expect(mapping["xl"] == 1280, "xl short edge = 1280")
expect(mapping["m"] == 320, "m short edge = 320")
expect(mapping["sm"] == 240, "sm short edge = 240")
expect(Thumbnailer.shortEdges.count == 3, "exactly three sizes")
expect(Thumbnailer.locateFFmpeg() != nil, "ffmpeg discoverable")

// MARK: - Settings round trip

print("Settings")
var o = EngineOptions()
o.mode = .full
o.strategy = .remote
o.frameFraction = 0.25
o.skipLargerThanBytes = 2_000_000_000
if let data = try? JSONEncoder().encode(o),
   let back = try? JSONDecoder().decode(EngineOptions.self, from: data) {
    expect(back.mode == .full, "mode survives encode/decode")
    expect(back.strategy == .remote, "strategy survives encode/decode")
    expect(abs(back.frameFraction - 0.25) < 0.0001, "frame fraction survives")
    expect(back.skipLargerThanBytes == 2_000_000_000, "size cap survives")
} else {
    checks += 1; failures += 1; print("  ✗ EngineOptions round trip failed")
}

// MARK: - Live thumbnail generation (real ffmpeg)

print("Thumbnail generation")
if let sample = ProcessInfo.processInfo.environment["SIA_TEST_VIDEO"],
   FileManager.default.fileExists(atPath: sample) {
    let out = tmp.appendingPathComponent("out", isDirectory: true)
    do {
        let set = try Thumbnailer.generate(input: URL(fileURLWithPath: sample),
                                           outDir: out, seconds: 1.0)
        expect(set.width == 2276 && set.height == 1280, "frame is 2276x1280 (got \(set.width)x\(set.height))")
        for url in [set.xl, set.m, set.sm] {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
            expect((size ?? 0) > 1000, "\(url.lastPathComponent) is non-trivial")
        }
    } catch {
        checks += 1; failures += 1; print("  ✗ generation failed: \(error)")
    }
} else {
    print("  (skipped: set SIA_TEST_VIDEO=/path/to/video to include this)")
}

// MARK: - Audit (proves originals untouched)

print("Audit")
do {
    let a = tmp.appendingPathComponent("a.bin")
    let b = tmp.appendingPathComponent("b.bin")
    try Data(repeating: 0x11, count: 4096).write(to: a)
    try Data(repeating: 0x22, count: 4096).write(to: b)
    let before = Audit.snapshot([a, b])
    expect(before.count == 2, "snapshot covers both files")
    let after = Audit.snapshot([a, b])
    expect(Audit.differences(before: before, after: after).isEmpty, "unchanged files -> no diff")

    try Data(repeating: 0x33, count: 4096).write(to: b)
    let mutated = Audit.snapshot([a, b])
    let diff = Audit.differences(before: before, after: mutated)
    expect(diff == [b.path], "changed file is reported (got \(diff.count))")
} catch {
    checks += 1; failures += 1; print("  ✗ audit test failed: \(error)")
}

// default must stay off: the app may never write without explicit opt-in
expect(EngineOptions().autoUpload == false, "autoUpload defaults to false")

// MARK: - Report

try? FileManager.default.removeItem(at: tmp)
print("")
if failures == 0 {
    print("✅ \(checks) checks passed")
    exit(0)
} else {
    print("❌ \(failures) of \(checks) checks failed")
    exit(1)
}
