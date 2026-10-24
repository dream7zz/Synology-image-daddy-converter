import Foundation

/// Reads an MP4 whose index (moov) sits at the end of the file.
///
/// AVFoundation can normally handle this through range requests, but it gives up
/// on large XAVC recordings. Instead of downloading a prefix (useless without the
/// index) we fetch only: the tail to locate `moov`, the `moov` box, and the byte
/// range of the first video sample. Those pieces are written into a sparse file
/// at their real offsets, which ffmpeg can then decode.
public enum MP4TailIndex {

    public struct Sample {
        public let offset: Int
        public let size: Int
    }

    public struct Index {
        public let total: Int
        public let moovOffset: Int
        public let moov: Data
        public let firstSample: Sample?
    }

    /// Range read helper.
    private static func read(_ client: NASClient, _ itemID: Int, _ start: Int, _ end: Int) throws -> Data {
        let (data, resp) = try client.raw(api: "SYNO.FotoTeam.Download",
                                          version: "1",
                                          method: "download",
                                          params: ["item_id": "[\(itemID)]"],
                                          rangeHeader: "bytes=\(start)-\(end)")
        guard resp.statusCode < 400, !data.isEmpty else { throw MP4Error.http(resp.statusCode) }
        return data
    }

    private static func totalSize(_ client: NASClient, _ itemID: Int) throws -> Int {
        let (_, resp) = try client.raw(api: "SYNO.FotoTeam.Download",
                                       version: "1",
                                       method: "download",
                                       params: ["item_id": "[\(itemID)]"],
                                       rangeHeader: "bytes=0-0")
        guard let cr = resp.value(forHTTPHeaderField: "Content-Range"),
              let slash = cr.lastIndex(of: "/"),
              let total = Int(cr[cr.index(after: slash)...].trimmingCharacters(in: .whitespaces)) else {
            throw MP4Error.noLength
        }
        return total
    }

    private struct Box { let type: String; let offset: Int; let size: Int; let header: Int }

    private static func boxes(_ data: Data, _ start: Int, _ end: Int) -> [Box] {
        var out: [Box] = []
        var off = start
        while off + 8 <= end {
            let size = Int(data.beUInt32(off))
            let type = data.beString(off + 4, 4)
            var header = 8
            var boxSize = size
            if size == 1 {
                guard off + 16 <= end else { break }
                boxSize = Int(data.beUInt64(off + 8))
                header = 16
            } else if size == 0 {
                boxSize = end - off
            }
            guard boxSize >= header, off + boxSize <= end else { break }
            out.append(Box(type: type, offset: off, size: boxSize, header: header))
            off += boxSize
        }
        return out
    }

    private static func find(_ data: Data, _ start: Int, _ end: Int, _ path: String) -> Box? {
        for box in boxes(data, start, end) {
            if box.type == path { return box }
            if ["moov", "trak", "mdia", "minf", "stbl"].contains(box.type),
               let hit = find(data, box.offset + box.header, box.offset + box.size, path) {
                return hit
            }
        }
        return nil
    }

    /// Walks top-level boxes (16 bytes per step) to find `moov` wherever it is.
    /// Needed for files whose index sits between mdat chunks.
    private static func locateByWalking(_ client: NASClient, itemID: Int, total: Int) throws -> Int? {
        var offset = 0
        var steps = 0
        while offset + 8 <= total, steps < 400 {
            let header = try read(client, itemID, offset, min(offset + 15, total - 1))
            guard header.count >= 8 else { return nil }
            var size = Int(header.beUInt32(0))
            let type = header.beString(4, 4)
            if size == 1, header.count >= 16 { size = Int(header.beUInt64(8)) }
            if size == 0 { size = total - offset }
            if type == "moov" { return offset }
            guard size >= 8 else { return nil }   // malformed chain
            offset += size
            steps += 1
        }
        return nil
    }

    /// Locates the moov box from the tail and reads the first video sample's range.
    public static func inspect(client: NASClient, itemID: Int) throws -> Index {
        let total = try totalSize(client, itemID)
        let window = min(2 << 20, total)
        let tailStart = total - window
        let tail = try read(client, itemID, tailStart, total - 1)

        var moovStart: Int?
        if let range = tail.range(of: Data("moov".utf8), options: .backwards),
           range.lowerBound >= 4 {
            moovStart = tailStart + range.lowerBound - 4
        } else {
            // Index not in the last 2 MB: walk the box chain instead.
            moovStart = try locateByWalking(client, itemID: itemID, total: total)
        }
        guard let moovStart else { throw MP4Error.noMoov }
        let header = try read(client, itemID, moovStart, moovStart + 15)
        var moovSize = Int(header.beUInt32(0))
        if moovSize == 1 { moovSize = Int(header.beUInt64(8)) }
        guard moovSize >= 8, moovSize < (64 << 20) else { throw MP4Error.badMoov }
        let moov = try read(client, itemID, moovStart, moovStart + moovSize - 1)

        var sample: Sample?
        if let stco = find(moov, 0, moov.count, "stco") ?? find(moov, 0, moov.count, "co64"),
           let stsz = find(moov, 0, moov.count, "stsz") {
            let firstChunk = Int(moov.beUInt32(stco.offset + stco.header + 8))
            let constantSize = Int(moov.beUInt32(stsz.offset + stsz.header + 4))
            let size = constantSize != 0 ? constantSize
                                         : Int(moov.beUInt32(stsz.offset + stsz.header + 12))
            if firstChunk > 0, size > 0, firstChunk + size <= total {
                sample = Sample(offset: firstChunk, size: size)
            }
        }
        return Index(total: total, moovOffset: moovStart, moov: moov, firstSample: sample)
    }

    /// Builds the sparse file: ftyp header + first sample + moov at real offsets.
    public static func materialize(client: NASClient, itemID: Int, index: Index, path: URL,
                                   headBytes: Int = 1 << 20) throws {
        let headEnd = min(headBytes, index.total) - 1
        let head = try read(client, itemID, 0, headEnd)
        var sample: Data?
        if let s = index.firstSample {
            // One sample can be a few MB; cap it so a broken index cannot pull GBs.
            let capped = min(s.size, 8 << 20)
            sample = try read(client, itemID, s.offset, s.offset + capped - 1)
        }

        try? FileManager.default.removeItem(at: path)
        FileManager.default.createFile(atPath: path.path, contents: nil)
        let handle = try FileHandle(forWritingTo: path)
        defer { try? handle.close() }
        try handle.write(contentsOf: head)
        if let sample, let s = index.firstSample {
            try handle.seek(toOffset: UInt64(s.offset))
            try handle.write(contentsOf: sample)
        }
        try handle.seek(toOffset: UInt64(index.moovOffset))
        try handle.write(contentsOf: index.moov)
        try handle.truncate(atOffset: UInt64(index.total))
    }

    public enum MP4Error: Error, CustomStringConvertible {
        case noLength, noMoov, badMoov, http(Int), noSample

        public var description: String {
            switch self {
            case .noLength: return "无法获取文件长度"
            case .noMoov: return "文件尾部没有 moov 索引"
            case .badMoov: return "moov 索引长度异常"
            case .http(let code): return "读取失败（HTTP \(code)）"
            case .noSample: return "索引中没有视频样本"
            }
        }
    }
}

private extension Data {
    func beUInt32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        return withUnsafeBytes { raw in
            let base = raw.bindMemory(to: UInt8.self)
            return UInt32(base[offset]) << 24 | UInt32(base[offset + 1]) << 16
                | UInt32(base[offset + 2]) << 8 | UInt32(base[offset + 3])
        }
    }

    func beUInt64(_ offset: Int) -> UInt64 {
        guard offset >= 0, offset + 8 <= count else { return 0 }
        return UInt64(beUInt32(offset)) << 32 | UInt64(beUInt32(offset + 4))
    }

    func beString(_ offset: Int, _ length: Int) -> String {
        guard offset >= 0, offset + length <= count else { return "" }
        return String(decoding: self[offset..<(offset + length)], as: UTF8.self)
    }
}
