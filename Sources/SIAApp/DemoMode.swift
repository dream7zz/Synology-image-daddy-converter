import AppKit
import SIACore

/// Synthetic library used only for documentation screenshots.
///
/// Enabled with `SIA_DEMO=1`. It never touches the network: the items, the
/// queue and the thumbnails are generated locally so the UI can be captured
/// without exposing a real photo library.
enum DemoMode {
    static var isOn: Bool {
        ProcessInfo.processInfo.environment["SIA_DEMO"] == "1"
    }

    static var showQueue: Bool {
        ProcessInfo.processInfo.environment["SIA_DEMO_QUEUE"] == "1"
    }

    struct Snapshot {
        var account: Account
        var roots: [FolderEntry]
        var folders: [FolderEntry]
        var items: [PhotoItem]
        var jobs: [Int: Job]
        var running: Bool
    }

    /// Two roots with sub-folders, so the tree shows real hierarchy.
    private static let roots: [(path: String, id: Int)] = [
        ("/Photos", 100),
        ("/Videos", 200),
    ]

    private static let folders: [(path: String, id: Int)] = [
        ("/Photos/Trips", 101),
        ("/Photos/Family", 102),
        ("/Photos/Drone", 103),
        ("/Videos/Camera", 201),
        ("/Videos/Phone", 202),
    ]

    private static let names: [String] = [
        "IMG_0421.HEIC", "IMG_0422.HEIC", "IMG_0430.HEIC", "IMG_0431.HEIC",
        "IMG_1102.JPG", "IMG_1103.JPG", "IMG_1104.JPG", "IMG_1105.JPG",
        "DSC_8811.NEF", "DSC_8812.NEF", "DSC_8813.NEF",
        "PXL_20240815_101500.jpg", "PXL_20240815_101800.jpg",
        "VID_20240815_120000.mp4", "VID_20240815_120300.mp4",
        "DJI_0007.MP4", "DJI_0008.MP4", "DJI_0012.MP4", "DJI_0019.MP4",
        "GX010031.MP4", "GX010032.MP4",
        "CLIP_0001.MOV", "CLIP_0002.MOV",
        "IMG_2201.HEIC", "IMG_2202.HEIC", "IMG_2210.HEIC",
        "IMG_3301.JPG", "IMG_3302.JPG",
        "MVI_0042.MOV", "MVI_0043.MOV",
        "PANO_0001.jpg", "PANO_0002.jpg",
    ]

    static func snapshot() -> Snapshot {
        var items: [PhotoItem] = []
        var rootFolders: [FolderEntry] = []
        var entries: [FolderEntry] = []
        var id = 9_000

        for (folderPath, folderID) in roots {
            let entry = FolderEntry(id: folderID,
                                    name: String(folderPath.dropFirst()),
                                    path: folderPath)
            rootFolders.append(entry)
            entries.append(entry)
        }
        for (folderPath, folderID) in folders {
            let name = folderPath.split(separator: "/").dropFirst().joined(separator: "/")
            entries.append(FolderEntry(id: folderID, name: name, path: folderPath))
        }

        for (folderIndex, folder) in folders.enumerated() {
            for offset in 0..<8 {
                id += 1
                let filename = names[(folderIndex * 8 + offset) % names.count]
                var isVideo = ["mp4", "mov"].contains((filename as NSString).pathExtension.lowercased())
                // Invalid entries must be video: a tiny .jpg is still a photo.
                let isInvalid = offset == 7 && folderIndex % 2 == 0
                var name = filename
                if isInvalid {
                    name = "VID_00\(folderIndex)7.mp4"
                    isVideo = true
                }
                let ready = !isInvalid && (folderIndex + offset) % 4 != 0
                let state: PreviewState = ready ? .ready : .ameDefect
                let sizes: [String: String] = ready
                    ? ["sm": "ready", "m": "ready", "xl": "ready"]
                    : ["sm": "ame_defect", "m": "ame_defect", "xl": "ame_defect"]
                items.append(PhotoItem(
                    id: id,
                    filename: name,
                    type: isVideo ? "video" : "photo",
                    bytes: isInvalid ? (folderIndex % 4 == 0 ? 0 : 274) : (isVideo ? 420 << 20 : 3 << 20),
                    folderId: folder.id,
                    folderPath: folder.path,
                    state: state,
                    codec: isVideo ? "hevc" : nil,
                    width: isVideo ? 3840 : 4032,
                    height: isVideo ? 2160 : 3024,
                    cacheKey: "demo-\(id)",
                    convertedVariants: 0,
                    sizeStates: sizes))
            }
        }

        // A queue that exercises every column we care about.
        var jobs: [Int: Job] = [:]
        let missing = items.filter { $0.state != .ready }
        for (index, item) in missing.enumerated() {
            let stage: JobStage
            switch index {
            case 0: stage = .fetching
            case 1: stage = .converting
            case 2: stage = .uploading
            case 3, 4: stage = .pending
            case 5, 6: stage = .failed
            case 7: stage = .blocked
            case 8: stage = .skipped
            case 9, 10, 11: stage = .done
            default: stage = .pending
            }
            let message: String
            switch stage {
            case .fetching: message = "读取前段数据…"
            case .converting: message = "生成缩略图中…"
            case .uploading: message = "上传中… 3 个文件"
            case .pending: message = ""
            case .failed: message = "解码失败：ffmpeg exit 234"
            case .blocked: message = "NAS 侧转换任务卡死（源文件不完整），无法写入缩略图"
            case .skipped: message = "无效数据（274 字节），无法处理"
            case .done: message = "已上传，预览应已可见"
            default: message = ""
            }
            jobs[item.id] = Job(id: item.id, filename: item.filename, bytes: item.bytes,
                                folderPath: item.folderPath, stage: stage,
                                message: message, thumbDir: nil,
                                progress: stage == .fetching ? 0.42 : 1,
                                updatedAt: Date())
        }

        return Snapshot(
            account: Account(displayName: "Home NAS", host: "home.local:5001",
                             username: "demo"),
            roots: rootFolders,
            folders: entries,
            items: items,
            jobs: jobs,
            running: showQueue)
    }

    /// Placeholder artwork so screenshots never contain real photos.
    static func placeholder(for item: PhotoItem) -> NSImage? {
        let size = NSSize(width: 960, height: 540)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let palette: [(NSColor, NSColor)] = [
            (NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.24, alpha: 1),
             NSColor(calibratedRed: 0.24, green: 0.32, blue: 0.45, alpha: 1)),
            (NSColor(calibratedRed: 0.18, green: 0.22, blue: 0.18, alpha: 1),
             NSColor(calibratedRed: 0.32, green: 0.40, blue: 0.30, alpha: 1)),
            (NSColor(calibratedRed: 0.24, green: 0.18, blue: 0.14, alpha: 1),
             NSColor(calibratedRed: 0.44, green: 0.32, blue: 0.22, alpha: 1)),
        ]
        let pair = palette[abs(item.id) % palette.count]
        let gradient = NSGradient(starting: pair.0, ending: pair.1)
        gradient?.draw(in: NSRect(origin: .zero, size: size), angle: 35)

        // Abstract shapes: enough to read as a photo, contains no real content.
        NSColor.black.withAlphaComponent(0.16).setFill()
        NSRect(x: 0, y: 0, width: size.width, height: size.height * 0.38).fill()

        let sun = NSBezierPath(ovalIn: NSRect(x: size.width * 0.66, y: size.height * 0.52,
                                              width: size.width * 0.18,
                                              height: size.width * 0.18))
        NSColor.white.withAlphaComponent(0.18).setFill()
        sun.fill()

        let ridge = NSBezierPath()
        ridge.move(to: NSPoint(x: 0, y: size.height * 0.38))
        ridge.line(to: NSPoint(x: size.width * 0.28, y: size.height * 0.62))
        ridge.line(to: NSPoint(x: size.width * 0.46, y: size.height * 0.44))
        ridge.line(to: NSPoint(x: size.width * 0.68, y: size.height * 0.70))
        ridge.line(to: NSPoint(x: size.width, y: size.height * 0.40))
        ridge.line(to: NSPoint(x: size.width, y: 0))
        ridge.line(to: NSPoint(x: 0, y: 0))
        ridge.close()
        NSColor.black.withAlphaComponent(0.22).setFill()
        ridge.fill()
        return image
    }
}
