import AppKit
import QuickLookThumbnailing
import SwiftUI

/// Quick Look thumbnails (the Finder's), cached; file icons while they load or when there's none.
@MainActor
enum Thumbnails {
    private static let cache = NSCache<NSString, NSImage>()

    private static func key(_ url: URL, _ size: CGFloat) -> NSString {
        let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return "\(url.path)|\(Int(size))|\(modified?.timeIntervalSince1970 ?? 0)" as NSString
    }

    /// Largest cached thumbnail of the file, for drag images.
    static func cachedImage(for url: URL) -> NSImage? {
        for size in [CGFloat(120), 64, 32] {
            if let image = cache.object(forKey: key(url, size)) { return image }
        }
        return nil
    }

    static func image(for url: URL, size: CGFloat) async -> NSImage {
        let cacheKey = key(url, size)
        if let cached = cache.object(forKey: cacheKey) { return cached }
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: size, height: size),
                                                   scale: scale, representationTypes: .thumbnail)
        let image: NSImage
        if let thumbnail = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
            image = thumbnail.nsImage
        } else {
            image = NSWorkspace.shared.icon(forFile: url.path)
        }
        cache.setObject(image, forKey: cacheKey)
        return image
    }
}

struct FileThumbnail: View {
    let url: URL
    var size: CGFloat = 32
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else {
                Image(nsImage: NSWorkspace.shared.icon(forFile: url.path)).resizable().aspectRatio(contentMode: .fit)
            }
        }
        .frame(width: size, height: size)
        .task(id: url) { image = await Thumbnails.image(for: url, size: size) }
    }
}
