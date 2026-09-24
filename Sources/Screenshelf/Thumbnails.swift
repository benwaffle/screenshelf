import AppKit
import ImageIO
import SwiftUI

/// Downsampled thumbnails, decoded off the main thread and cached in memory.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    func cached(_ path: String, maxPixelSize: Int) -> NSImage? {
        cache.object(forKey: key(path, maxPixelSize))
    }

    func image(for path: String, maxPixelSize: Int) async -> NSImage? {
        if let hit = cached(path, maxPixelSize: maxPixelSize) { return hit }
        let cg = await Self.decode(path, maxPixelSize: maxPixelSize)
        guard let cg else { return nil }
        let image = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(image, forKey: key(path, maxPixelSize))
        return image
    }

    private func key(_ path: String, _ size: Int) -> NSString { "\(size)|\(path)" as NSString }

    @concurrent
    private static func decode(_ path: String, maxPixelSize: Int) async -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

struct Thumbnail: View {
    let path: String
    var maxPixelSize = 640
    var contentMode: ContentMode = .fill

    @State private var image: NSImage?

    var body: some View {
        // Color.clear takes exactly the offered size; the image is drawn in an overlay so an unusual aspect ratio
        // can never make the thumbnail report a larger size than its cell.
        Color.clear
            .overlay(alignment: .top) {
                if let image = image ?? ThumbnailCache.shared.cached(path, maxPixelSize: maxPixelSize) {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: contentMode)
                } else {
                    Rectangle().fill(.quaternary)
                }
            }
            .clipped()
        .task(id: "\(maxPixelSize)|\(path)") {
            image = await ThumbnailCache.shared.image(for: path, maxPixelSize: maxPixelSize)
        }
    }
}
