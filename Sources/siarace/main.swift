import Foundation
import SIACore

// Race harness for ThumbnailClient's in-memory cache.
//
// Reproduces the crash shape reported on 2026-10-22: many cooperative-pool
// threads calling thumbnail() at once, all reaching `memory[key] = data`.
// Every call below is a guaranteed disk-cache hit, so no network is involved
// and the only shared mutable state touched is ThumbnailClient.memory.
//
// Run under ThreadSanitizer:
//   swift run --sanitize=thread siarace 32 400

/// Control group: the pre-fix implementation, identical except for the missing
/// lock. TSan must flag this, which proves the harness can detect the race.
final class UnsafeClient {
    var memory: [String: Data] = [:]
    let root: URL
    init(root: URL) { self.root = root }
    func load(id: Int, v: String) -> Data? {
        let key = "\(id)-sm-\(v)"
        if let hit = memory[key] { return hit }
        let url = root.appendingPathComponent("\(id)_sm_\(v).jpg")
        guard let d = try? Data(contentsOf: url) else { return nil }
        memory[key] = d
        return d
    }
}

let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "safe"
let threads = CommandLine.arguments.count > 2 ? Int(CommandLine.arguments[2]) ?? 32 : 32
let iterations = CommandLine.arguments.count > 3 ? Int(CommandLine.arguments[3]) ?? 400 : 400

let account = UUID()
let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    .appendingPathComponent("SIA-Lite/thumbs/\(account.uuidString)", isDirectory: true)
try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

// A payload shaped like a JPEG header; ThumbnailClient only requires >100 bytes
// on the disk path.
var blob = Data([0xFF, 0xD8, 0xFF, 0xE0])
blob.append(Data(repeating: 0x42, count: 512))

let ids = Array(1...80)  // 80 ids x 8 versions = 640 keys > memoryLimit, so eviction runs
let versions = (0..<8).map { "v\($0)" }
for id in ids {
    for v in versions {
        try? blob.write(to: root.appendingPathComponent("\(id)_sm_\(v).jpg"))
    }
}

let client = ThumbnailClient(client: NASClient(host: "invalid.local", account: "x", password: ""),
                             accountID: account)
let unsafeClient = UnsafeClient(root: root)

let group = DispatchGroup()
let queue = DispatchQueue(label: "race", attributes: .concurrent)
var nonNil = 0
let counterLock = NSLock()

for _ in 0..<threads {
    group.enter()
    queue.async {
        for i in 0..<iterations {
            let id = ids[(i &* 7 &+ Int.random(in: 0..<ids.count)) % ids.count]
            let v = versions[i % versions.count]
            let got = mode == "unsafe"
                ? unsafeClient.load(id: id, v: v)
                : client.thumbnail(id: id, cacheKey: v, size: .sm)
            if got != nil {
                counterLock.lock(); nonNil += 1; counterLock.unlock()
            }
        }
        group.leave()
    }
}

group.wait()
let expected = threads * iterations
print("mode=\(mode) threads=\(threads) iterations=\(iterations) calls=\(expected) hits=\(nonNil)")
exit(nonNil == expected ? 0 : 1)
