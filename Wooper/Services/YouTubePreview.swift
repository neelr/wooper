import Foundation
import CoreGraphics
import ImageIO

struct YouTubeVideo: Equatable, Sendable {
    let id: String

    init?(_ raw: String) {
        guard let url = URLComponents(string: raw),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return nil }
        let path = url.path.split(separator: "/").map(String.init)
        let candidate: String?
        switch host {
        case "youtu.be", "www.youtu.be": candidate = path.first
        case "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
             "youtube-nocookie.com", "www.youtube-nocookie.com":
            if path.first == "watch" {
                candidate = url.queryItems?.first(where: { $0.name == "v" })?.value
            } else if path.count == 2, ["shorts", "live", "embed", "v"].contains(path[0]) {
                candidate = path[1]
            } else { candidate = nil }
        default: return nil
        }
        guard let candidate, candidate.utf8.count == 11,
              candidate.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                  (48...57).contains($0) || $0 == 45 || $0 == 95 }) else { return nil }
        id = candidate
    }

    var watchURL: URL { URL(string: "https://www.youtube.com/watch?v=\(id)&hl=en")! }

    func fallbackURLs(sample: Double) -> [URL] {
        let index = min(2, Int(Self.unit(sample) * 3)) + 1
        // These numbered images are video stills, not the uploader's cover art.
        return ["hq\(index)", "\(index)"].map { URL(string: "https://i.ytimg.com/vi/\(id)/\($0).jpg")! }
    }

    static func unit(_ sample: Double) -> Double {
        sample.isFinite ? min(1, max(0, sample)) : 0.5
    }
}

struct YouTubeStoryboard: Sendable {
    struct Frame: Sendable {
        let url: URL
        let rect: CGRect
    }
    let template: String
    let level: Int
    let width: Int
    let height: Int
    let count: Int
    let columns: Int
    let rows: Int
    let name: String
    let signature: String

    static func parse(html: String, video: YouTubeVideo) -> Self? {
        let pattern = #""playerStoryboardSpecRenderer"\s*:\s*\{[^{}]*?"spec"\s*:\s*("(?:\\.|[^"\\])*")"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let range = Range(match.range(at: 1), in: html),
              let spec = try? JSONDecoder().decode(String.self, from: Data(html[range].utf8)) else { return nil }
        return parse(spec: spec, video: video)
    }

    static func parse(spec: String, video: YouTubeVideo) -> Self? {
        let parts = spec.components(separatedBy: "|")
        guard let template = parts.first, let url = URL(string: template),
              url.scheme == "https", let host = url.host,
              host.hasSuffix(".ytimg.com"), url.port == nil, url.user == nil,
              url.path.hasPrefix("/sb/\(video.id)/") else { return nil }
        return parts.dropFirst().enumerated().compactMap { level, raw -> Self? in
            let fields = raw.components(separatedBy: "#")
            guard fields.count == 8,
                  let width = Int(fields[0]), (1...4096).contains(width),
                  let height = Int(fields[1]), (1...4096).contains(height),
                  let count = Int(fields[2]), (1...1_000_000).contains(count),
                  let columns = Int(fields[3]), (1...100).contains(columns),
                  let rows = Int(fields[4]), (1...100).contains(rows),
                  width * columns * height * rows <= 16_000_000 else { return nil }
            return Self(template: template, level: level, width: width, height: height,
                        count: count, columns: columns, rows: rows, name: fields[6], signature: fields[7])
        }.max { $0.width * $0.height < $1.width * $1.height }
    }

    func frame(sample: Double) -> Frame? {
        // Avoid the first/last few stills, which often contain a fade or end card.
        let first = count >= 20 ? count / 20 : 0
        let last = count - 1 - first
        let index = min(last, first + Int(YouTubeVideo.unit(sample) * Double(last - first + 1)))
        let perSheet = columns * rows
        let address = template.replacingOccurrences(of: "$L", with: String(level))
            .replacingOccurrences(of: "$N", with: name)
            .replacingOccurrences(of: "$M", with: String(index / perSheet))
        guard var components = URLComponents(string: address) else { return nil }
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "sigh", value: signature)]
        guard let url = components.url else { return nil }
        let cell = index % perSheet
        return Frame(url: url, rect: CGRect(x: cell % columns * width, y: cell / columns * height,
                                            width: width, height: height))
    }
}

/// Fetches small, public storyboard sheets; never starts playback or downloads
/// the video. Metadata and decoded sheets are bounded and shared across previews.
actor YouTubePreview {
    static let shared = YouTubePreview()
    private struct Entry { let date: Date; let storyboard: YouTubeStoryboard? }
    private var metadata: [String: Entry] = [:]
    private var pending: [String: Task<YouTubeStoryboard?, Never>] = [:]
    private let sheets = NSCache<NSURL, CGImage>()
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 15
        session = URLSession(configuration: config)
        sheets.countLimit = 24
        sheets.totalCostLimit = 24 * 1024 * 1024
    }

    func image(for video: YouTubeVideo, sample: Double) async -> CGImage? {
        if let storyboard = await storyboard(for: video), !Task.isCancelled,
           let frame = storyboard.frame(sample: sample),
           let sheet = await image(at: frame.url), !Task.isCancelled,
           let result = Self.crop(sheet, to: frame.rect) { return result }
        for url in video.fallbackURLs(sample: sample) {
            guard !Task.isCancelled else { return nil }
            if let image = await image(at: url), image.width >= 120, image.height >= 90 { return image }
        }
        return nil
    }

    private func storyboard(for video: YouTubeVideo) async -> YouTubeStoryboard? {
        if let entry = metadata[video.id], Date().timeIntervalSince(entry.date) < (entry.storyboard == nil ? 120 : 900) {
            return entry.storyboard
        }
        if let task = pending[video.id] { return await task.value }
        let task = Task { [session] in
            var request = URLRequest(url: video.watchURL)
            request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
            request.setValue("text/html", forHTTPHeaderField: "Accept")
            guard let (data, response) = try? await session.data(for: request),
                  (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024,
                  let html = String(data: data, encoding: .utf8) else { return Optional<YouTubeStoryboard>.none }
            return YouTubeStoryboard.parse(html: html, video: video)
        }
        pending[video.id] = task
        let storyboard = await task.value
        pending[video.id] = nil
        if metadata.count >= 100, let oldest = metadata.min(by: { $0.value.date < $1.value.date })?.key {
            metadata[oldest] = nil
        }
        metadata[video.id] = Entry(date: Date(), storyboard: storyboard)
        return storyboard
    }

    private func image(at url: URL) async -> CGImage? {
        if let image = sheets.object(forKey: url as NSURL) { return image }
        guard let (data, response) = try? await session.data(from: url), !Task.isCancelled,
              (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 8 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 16000, height <= 16000, width * height <= 16_000_000,
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        sheets.setObject(image, forKey: url as NSURL, cost: image.bytesPerRow * image.height)
        return image
    }

    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        guard CGRect(x: 0, y: 0, width: image.width, height: image.height).contains(rect),
              let crop = image.cropping(to: rect),
              let context = CGContext(data: nil, width: crop.width, height: crop.height,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        // Copy only the selected cell so a tiny cached preview doesn't retain a whole sheet.
        context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        return context.makeImage()
    }
}
