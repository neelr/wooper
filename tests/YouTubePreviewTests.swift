import Foundation
import CoreGraphics
import ImageIO

@main struct YouTubePreviewTests {
    static func main() async throws {
        let id = "aqz-KE-bpKQ"
        let video = YouTubeVideo("https://www.youtube.com/watch?v=\(id)")!
        for raw in ["https://youtu.be/\(id)?t=30", "https://m.youtube.com/watch?x=1&v=\(id)",
                    "https://youtube.com/shorts/\(id)", "https://youtube.com/live/\(id)",
                    "https://www.youtube-nocookie.com/embed/\(id)", "https://music.youtube.com/watch?v=\(id)"] {
            assert(YouTubeVideo(raw) == video, raw)
        }
        for raw in ["https://youtube.com.evil.test/watch?v=\(id)", "https://evil.test/\(id)",
                    "https://youtube.com/@channel", "https://youtube.com/playlist?list=\(id)",
                    "https://youtu.be/bad", "file://youtube.com/watch?v=\(id)",
                    "https://youtube.com/watch?v=aqz-KE-bpK!"] {
            assert(YouTubeVideo(raw) == nil, raw)
        }
        let base = "https://i.ytimg.com/sb/\(id)/storyboard3_L$L/$N.jpg?sqp=example"
        let spec = base + "|1#1#5#2#2#1000#M$M#small|2#2#5#2#2#1000#M$M#rs$signed"
        let storyboard = YouTubeStoryboard.parse(spec: spec, video: video)!
        assert(storyboard.level == 1 && storyboard.width == 2)
        let first = storyboard.frame(sample: 0)!
        assert(first.url.path.hasSuffix("storyboard3_L1/M0.jpg"))
        assert(URLComponents(url: first.url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "rs$signed")
        assert(first.rect == CGRect(x: 0, y: 0, width: 2, height: 2))
        assert(storyboard.frame(sample: 0.25)!.rect == CGRect(x: 2, y: 0, width: 2, height: 2))
        assert(storyboard.frame(sample: 0.5)!.rect == CGRect(x: 0, y: 2, width: 2, height: 2))
        let last = storyboard.frame(sample: 1)!
        assert(last.url.path.hasSuffix("M1.jpg") && last.rect == first.rect,
               "A partial final sheet must not select one of its empty cells")
        assert(storyboard.frame(sample: -.infinity) != nil)
        let encoded = String(data: try JSONEncoder().encode(spec), encoding: .utf8)!
        let html = "<script>var player={\"storyboards\":{\"playerStoryboardSpecRenderer\":{\"spec\":\(encoded)}}}</script>"
        assert(YouTubeStoryboard.parse(html: html, video: video)?.width == 2)
        assert(YouTubeStoryboard.parse(html: "<html>consent required</html>", video: video) == nil)
        for bad in [base + "|0#2#5#2#2#1000#M$M#sig", base + "|2#2#5#999999999999#2#1000#M$M#sig",
                    spec.replacingOccurrences(of: "i.ytimg.com", with: "i.ytimg.com.evil.test"),
                    spec.replacingOccurrences(of: "/sb/\(id)/", with: "/sb/differentID/")] {
            assert(YouTubeStoryboard.parse(spec: bad, video: video) == nil)
        }
        let long = YouTubeStoryboard.parse(spec: base + "|2#2#100#2#2#1000#M$M#sig", video: video)!
        assert(long.frame(sample: 0)!.url.path.hasSuffix("M1.jpg"), "Skip the opening fade")
        assert(long.frame(sample: 1)!.url.path.hasSuffix("M23.jpg"), "Skip the end card")
        assert(video.fallbackURLs(sample: 0)[0].lastPathComponent == "hq1.jpg")
        assert(video.fallbackURLs(sample: 1)[0].lastPathComponent == "hq3.jpg")

        // Known colored cells catch crop-coordinate errors and sheet leakage.
        let pixels = Data([255, 0, 0, 255, 0, 255, 0, 255,
                           0, 0, 255, 255, 255, 255, 0, 255])
        let source = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32,
                             bytesPerRow: 8, space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                             provider: CGDataProvider(data: pixels as CFData)!, decode: nil,
                             shouldInterpolate: false, intent: .defaultIntent)!
        let crop = YouTubePreview.crop(source, to: CGRect(x: 1, y: 0, width: 1, height: 1))!
        let cropBytes = crop.dataProvider!.data! as Data
        assert(crop.width == 1 && crop.height == 1 && cropBytes[0] == 0 && cropBytes[1] == 255 && cropBytes[2] == 0)
        assert(YouTubePreview.crop(source, to: CGRect(x: 2, y: 0, width: 1, height: 1)) == nil)
        print("PASS YouTube URL parsing, storyboard levels, signatures, frame selection, bounds, crop pixels, and fallbacks")

        if CommandLine.arguments.contains("--live") {
            var results: [Data] = []
            for (index, sample) in [0.24, 0.68].enumerated() {
                guard let image = await YouTubePreview.shared.image(for: video, sample: sample) else {
                    fatalError("Live video frame unavailable")
                }
                let data = NSMutableData()
                let output = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
                CGImageDestinationAddImage(output, image, nil)
                assert(CGImageDestinationFinalize(output))
                try (data as Data).write(to: URL(fileURLWithPath: "/tmp/youtube-preview-\(index).png"))
                results.append(data as Data)
                print("Live frame \(index): \(image.width)×\(image.height)")
            }
            assert(results[0] != results[1], "Different points in the video should give different stills")
            print("PASS live YouTube storyboard fetching and distinct frames")
            let shortVideo = YouTubeVideo("https://youtu.be/jNQXAC9IVRw")!
            guard let fallback = await YouTubePreview.shared.image(for: shortVideo, sample: 0.5) else {
                fatalError("Short video's numbered still unavailable")
            }
            assert(fallback.width >= 120 && fallback.height >= 90)
            print("PASS short-video still: \(fallback.width)×\(fallback.height)")
        }
    }
}
