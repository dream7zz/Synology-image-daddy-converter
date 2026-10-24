import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Photo thumbnails through ImageIO instead of ffmpeg.
///
/// ffmpeg cannot decode most RAW containers (DNG/CR2) and ignored EXIF
/// orientation; ImageIO handles HEIC, JPEG, TIFF, PNG, DNG and CR2, and applies
/// the orientation transform.
public enum ImageThumbnailer {
    public static let shortEdges: [(String, Int)] = [("xl", 1280), ("m", 320), ("sm", 240)]

    public static func generate(input: URL, outDir: URL, quality: Double = 0.86) throws -> ThumbnailSet {
        guard let source = CGImageSourceCreateWithURL(input as CFURL, nil) else {
            throw ImageThumbnailError.undecodable(input.lastPathComponent)
        }
        guard CGImageSourceGetCount(source) > 0 else {
            throw ImageThumbnailError.undecodable(input.lastPathComponent)
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let stem = input.deletingPathExtension().lastPathComponent

        var urls: [String: URL] = [:]
        var dimensions: (Int, Int) = (0, 0)
        for (name, edge) in shortEdges {
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: edge,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                throw ImageThumbnailError.undecodable(input.lastPathComponent)
            }
            if name == "xl" { dimensions = (image.width, image.height) }
            let dest = outDir.appendingPathComponent("\(stem)_\(name).jpg")
            try? FileManager.default.removeItem(at: dest)
            try writeJPEG(image, to: dest, quality: quality)
            urls[name] = dest
        }

        return ThumbnailSet(xl: urls["xl"]!,
                            m: urls["m"]!,
                            sm: urls["sm"]!,
                            width: dimensions.0,
                            height: dimensions.1)
    }

    static func writeJPEG(_ image: CGImage, to url: URL, quality: Double) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL,
                                                         UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ImageThumbnailError.encoding(url.lastPathComponent)
        }
        CGImageDestinationAddImage(dest, image,
                                   [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else {
            throw ImageThumbnailError.encoding(url.lastPathComponent)
        }
    }
}

public enum ImageThumbnailError: Error, CustomStringConvertible {
    case undecodable(String)
    case encoding(String)

    public var description: String {
        switch self {
        case .undecodable(let name): return "无法解码图像（\(name)）"
        case .encoding(let name): return "无法写入 JPEG（\(name)）"
        }
    }
}
