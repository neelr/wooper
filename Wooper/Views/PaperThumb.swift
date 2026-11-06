import SwiftUI
import ImageIO
import UIKit

/// YouTube previews use random video stills; other pages use /api/thumb, fetched with the
/// Bearer header (AsyncImage can't), downsampled to cell size, and memory-
/// cached so scrolling doesn't refetch. Server thumbs are durable in D1, so
/// saved papers resolve fast; HTTP-level caching also applies (max-age 7d).
struct PaperThumb: View {
    let url: String
    var width: CGFloat = 64
    var height: CGFloat = 48
    var alignment: Alignment = .center
    @Environment(\.displayScale) private var displayScale

    private var video: YouTubeVideo? { YouTubeVideo(url) }
    private var cacheKey: String { "\(url)|\(Int(max(width, height) * displayScale))|\(video == nil ? 0 : frameSample)" }

    private static let cache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.totalCostLimit = 32 * 1024 * 1024
        cache.countLimit = 100
        return cache
    }()

    @State private var image: UIImage?
    @State private var failed = false
    @State private var frameSample = Double.random(in: 0..<1)

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: video == nil ? .fill : .fit)
            } else {
                Rectangle()
                    .fill(Color.paperyMeta.opacity(failed ? 0.06 : 0.14))
            }
        }
        .frame(width: width, height: height, alignment: video == nil ? alignment : .center)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.paperyMeta.opacity(0.25), lineWidth: 0.5)
        )
        .task(id: cacheKey) { await load() }
    }

    private func load() async {
        let key = cacheKey
        image = nil
        failed = false
        if let cached = Self.cache.object(forKey: key as NSString) {
            image = cached
            return
        }
        if let video, let frame = await YouTubePreview.shared.image(for: video, sample: frameSample) {
            guard !Task.isCancelled else { return }
            let img = UIImage(cgImage: frame)
            Self.cache.setObject(img, forKey: key as NSString, cost: frame.bytesPerRow * frame.height)
            image = img
            return
        }
        guard !Task.isCancelled else { return }
        guard let req = try? PaperyService.thumbRequest(for: url) else {
            failed = true
            return
        }
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let img = Self.downsample(data: data, maxPixels: max(width, height) * displayScale)
            else {
                failed = true
                return
            }
            guard !Task.isCancelled else { return }
            Self.cache.setObject(img, forKey: key as NSString,
                                 cost: (img.cgImage?.bytesPerRow ?? 0) * (img.cgImage?.height ?? 0))
            image = img
        } catch {
            guard !Task.isCancelled else { return }
            failed = true
        }
    }

    /// Decode straight to thumbnail size — never materialises the full
    /// 1280x960 bitmap in memory.
    private static func downsample(data: Data, maxPixels: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixels,
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }
}
