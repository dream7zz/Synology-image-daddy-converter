import Foundation
import CryptoKit

/// Read-only proof that we did not touch the originals.
///
/// The promise "绝不删除修改原始文件" should be verifiable, not just asserted:
/// hash the originals before and after a run and require the two maps to be
/// identical. This only reads files.
public enum Audit {
    public static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while autoreleasepool(invoking: {
            let chunk = try? handle.read(upToCount: 1 << 20)
            guard let chunk, !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    public static func snapshot(_ urls: [URL]) -> [String: String] {
        var out: [String: String] = [:]
        for url in urls {
            if let digest = try? sha256(of: url) { out[url.path] = digest }
        }
        return out
    }

    /// Returns the paths whose digest changed, disappeared, or appeared.
    public static func differences(before: [String: String],
                                   after: [String: String]) -> [String] {
        var changed: [String] = []
        for (path, digest) in before {
            if after[path] != digest { changed.append(path) }
        }
        for path in after.keys where before[path] == nil {
            changed.append(path)
        }
        return changed.sorted()
    }
}
