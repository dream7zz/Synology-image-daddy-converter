import Foundation

/// Frame extraction + three-size JPEG generation.
///
/// Sizes mirror the original client, recovered from its own log line:
///   gen-thumbnail --input <f> --output-dir <d> --fit-short-edge 1280,320,240
/// i.e. the SHORT edge is 1280 (xl), 320 (m), 240 (sm); the long edge follows
/// the source aspect ratio, rounded to an even number for JPEG safety.
public struct ThumbnailSet {
    public let xl: URL
    public let m: URL
    public let sm: URL
    public let width: Int
    public let height: Int
}

public enum ThumbnailError: Error, CustomStringConvertible {
    case ffmpegMissing
    case failed(stage: String, status: Int32, stderr: String)
    case noOutput(String)

    public var description: String {
        switch self {
        case .ffmpegMissing:
            return "ffmpeg not found on PATH (brew install ffmpeg)"
        case let .failed(stage, status, stderr):
            return "ffmpeg \(stage) failed (exit \(status)): \(stderr.prefix(400))"
        case let .noOutput(path):
            return "ffmpeg reported success but produced no file at \(path)"
        }
    }
}

public enum Thumbnailer {
    public static let shortEdges: [(name: String, edge: Int)] = [
        ("xl", 1280), ("m", 320), ("sm", 240),
    ]

    public static func locateFFmpeg() -> URL? {
        for candidate in ["/opt/homebrew/bin/ffmpeg", "/usr/local/bin/ffmpeg", "/usr/bin/ffmpeg"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    @discardableResult
    private static func run(_ tool: URL, _ args: [String]) throws -> (Int32, String) {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let errPipe = Pipe()
        p.standardError = errPipe
        p.standardOutput = Pipe()
        try p.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: errData, encoding: .utf8) ?? "")
    }

    /// Runs a tool and returns (exit status, stdout). Used for ffprobe.
    private static func runCapturingStdout(_ tool: URL, _ args: [String]) -> (Int32, String) {
        let p = Process()
        p.executableURL = tool
        p.arguments = args
        let outPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = Pipe()
        do { try p.run() } catch { return (-1, "") }
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    /// Extracts one frame at `seconds` and writes the three JPEGs into `outDir`.
    public static func generate(input: URL,
                                outDir: URL,
                                seconds: Double = 1.0,
                                quality: Int = 3) throws -> ThumbnailSet {
        try generate(inputArgument: input.path,
                     stem: input.deletingPathExtension().lastPathComponent,
                     outDir: outDir, seconds: seconds, quality: quality)
    }

    /// Same pipeline but the input can be any ffmpeg-acceptable argument,
    /// including an http:// URL (the loopback proxy). `stem` names the output.
    public static func generate(inputArgument: String,
                                stem: String,
                                outDir: URL,
                                seconds: Double = 1.0,
                                quality: Int = 3) throws -> ThumbnailSet {
        guard let ffmpeg = locateFFmpeg() else { throw ThumbnailError.ffmpegMissing }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        var produced: [String: URL] = [:]

        // Decode exactly once. Three separate ffmpeg runs would decode the
        // source three times, which is wasteful locally and triples the traffic
        // when the input is a URL.
        let master = outDir.appendingPathComponent("\(stem)_master.png")
        try? FileManager.default.removeItem(at: master)
        var args = [
            "-hide_banner", "-loglevel", "error",
            // One frame needs a decoder setup, not a full probe. On a remote
            // input the default 5 MB probe is billed at NAS upstream speed.
            "-probesize", "2M", "-analyzeduration", "1M",
        ]
        // Seeking before the input makes ffmpeg jump to a timestamp; on a
        // sparse file that only holds the first sample the jump lands in a
        // hole, so 0 s must be decoded in place.
        if seconds > 0 {
            args += ["-ss", String(format: "%.3f", seconds)]
            args += ["-i", inputArgument]
        } else {
            args += ["-i", inputArgument]
        }
        args += ["-frames:v", "1", "-y", master.path]
        let (masterStatus, masterErr) = try run(ffmpeg, args)
        // A sparse or truncated input makes ffmpeg report NAL errors while
        // still writing the frame it managed to decode; the artifact is what
        // matters, and it is validated by re-opening it below.
        let masterBytes = (try? FileManager.default.attributesOfItem(atPath: master.path)[.size] as? Int)
            .flatMap { $0 } ?? 0
        guard masterBytes > 1024 else {
            throw ThumbnailError.failed(stage: "decode", status: masterStatus, stderr: masterErr)
        }
        _ = masterStatus

        // Then scale locally three times: cheap, no extra network.
        for (name, edge) in shortEdges {
            let dest = outDir.appendingPathComponent("\(stem)_\(name).jpg")
            try? FileManager.default.removeItem(at: dest)
            let vf = "scale='if(gt(iw,ih),-2,\(edge))':'if(gt(iw,ih),\(edge),-2)'"
            let (status, err) = try run(ffmpeg, [
                "-hide_banner", "-loglevel", "error",
                "-i", master.path,
                "-vf", vf,
                "-q:v", String(quality),
                "-y", dest.path,
            ])
            guard status == 0 else {
                throw ThumbnailError.failed(stage: "scale-\(name)", status: status, stderr: err)
            }
            guard FileManager.default.fileExists(atPath: dest.path) else {
                throw ThumbnailError.noOutput(dest.path)
            }
            produced[name] = dest
        }
        try? FileManager.default.removeItem(at: master)

        // Report the dimensions of the largest output for the progress ledger.
        var w = 0, h = 0
        if let ffprobe = locateFFprobe() {
            let (_, text) = runCapturingStdout(ffprobe, [
                "-v", "error", "-select_streams", "v:0",
                "-show_entries", "stream=width,height", "-of", "csv=p=0",
                produced["xl"]!.path,
            ])
            if let line = text.split(separator: "\n").first {
                let parts = line.split(separator: ",")
                if parts.count == 2 {
                    w = Int(parts[0].trimmingCharacters(in: .whitespaces)) ?? 0
                    h = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
        }

        return ThumbnailSet(xl: produced["xl"]!, m: produced["m"]!, sm: produced["sm"]!,
                            width: w, height: h)
    }

    public static func locateFFprobe() -> URL? {
        for candidate in ["/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe", "/usr/bin/ffprobe"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Duration in seconds, or nil when ffprobe is unavailable/unparseable.
    public static func duration(of input: URL) -> Double? {
        guard let probe = locateFFprobe() else { return nil }
        guard let (status, out) = try? run(probe, [
            "-v", "error", "-show_entries", "format=duration",
            "-of", "default=nw=1:nk=1", input.path,
        ]), status == 0 else { return nil }
        return Double(out.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
