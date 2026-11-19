import XCTest
import PencilKit
import WebKit
@testable import BrowserCheck

@MainActor final class BrowserCheckTests: XCTestCase {
    let url = URL(string: "https://example.com/article")!
    let fixture = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:0'><h1>Article</h1><a href='https://example.com/next'>Next article</a><div style='height:6000px;background:linear-gradient(white,lightyellow)'>Long page</div></body></html>"

    func testLightPressurePenRendersAndOldInvisibleInkIsRecovered() throws {
        func drawing(width: CGFloat, force: CGFloat) -> PKDrawing {
            let points = [CGPoint(x: 10, y: 20), CGPoint(x: 110, y: 20)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.1,
                              size: CGSize(width: width, height: width), opacity: 1,
                              force: force, azimuth: 1, altitude: 1.1)
            }
            return PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
                                                path: PKStrokePath(controlPoints: points, creationDate: Date()))])
        }
        func inkPixels(_ drawing: PKDrawing) -> Int {
            let image = drawing.image(from: CGRect(x: 0, y: 0, width: 130, height: 40), scale: 2).cgImage!
            var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
            bytes.withUnsafeMutableBytes { buffer in
                let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                                        bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            }
            return stride(from: 3, to: bytes.count, by: 4).filter { bytes[$0] > 16 }.count
        }
        for force: CGFloat in [0, 0.1, 1] {
            let pen = drawing(width: WebPenStyle.width(force: force, maximumForce: 4.166), force: force)
            XCTAssertGreaterThan(inkPixels(pen), 150, "Light or estimated pressure must still produce visible ink")
        }
        let old = drawing(width: 1.2, force: 1)
        let recovered = WebPenStyle.recoveringLegacyInk(in: old)
        XCTAssertGreaterThan(inkPixels(recovered), 150)
        XCTAssertEqual(recovered.strokes[0].path[0].location, old.strokes[0].path[0].location)
        XCTAssertEqual(recovered.strokes.count, old.strokes.count)
        XCTAssertEqual(WebPenStyle.recoveringLegacyInk(in: recovered), recovered, "Recovery must be idempotent")
        var marker = old.strokes[0]
        marker.ink = PKInk(.marker, color: .yellow)
        let highlight = PKDrawing(strokes: [marker])
        XCTAssertEqual(WebPenStyle.recoveringLegacyInk(in: highlight), highlight)
    }

    func loaded(_ controller: WebBrowserController, session: BrowserSession) async throws {
        controller.loadViewIfNeeded()
        controller.view.frame = CGRect(x: 0, y: 0, width: 900, height: 650)
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        controller.webView.loadHTMLString(fixture, baseURL: url)
        for _ in 0..<100 {
            if !session.loading && controller.webView.scrollView.contentSize.height > 1000 { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        XCTFail("Web fixture did not load")
    }

    func testInkPersistsFollowsScrollAndHidesWhenCompact() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = WebAnnotationStore(directory: folder)
        let session = BrowserSession(url: url)
        let controller = WebBrowserController(session: session, allowsAnnotations: true, store: store)
        try await loaded(controller, session: session)
        let points = [CGPoint(x: 100, y: 700), CGPoint(x: 220, y: 710)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 3, height: 3), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        controller.canvas.drawing = PKDrawing(strokes: [stroke])
        controller.canvasViewDrawingDidChange(controller.canvas)
        XCTAssertTrue(controller.saveNow())
        let saved = try XCTUnwrap(store.load(url))
        XCTAssertEqual(try PKDrawing(data: saved.drawing).strokes.count, 1)
        XCTAssertEqual(saved.pageWidth, 900)
        controller.webView.scrollView.contentOffset = CGPoint(x: 0, y: 500)
        XCTAssertEqual(controller.canvas.contentOffset.y, 500, accuracy: 0.1)
        XCTAssertEqual(controller.canvas.drawing.strokes[0].path[0].location.y, 700, accuracy: 0.1)
        controller.setAnnotationsAvailable(false)
        controller.view.frame.size.width = 390
        controller.view.layoutIfNeeded()
        XCTAssertTrue(controller.canvas.isHidden)
        XCTAssertEqual(controller.webView.bounds.width, 390, accuracy: 0.1)
        controller.setAnnotationsAvailable(true)
        controller.view.frame.size.width = 1000
        controller.view.layoutIfNeeded()
        XCTAssertFalse(controller.canvas.isHidden)
        XCTAssertEqual(controller.webView.bounds.width, 900, accuracy: 0.1)
        XCTAssertEqual(controller.canvas.drawing.strokes.count, 1)
        let reopenedSession = BrowserSession(url: url)
        let reopened = WebBrowserController(session: reopenedSession, allowsAnnotations: true, store: store)
        try await loaded(reopened, session: reopenedSession)
        XCTAssertEqual(reopened.canvas.drawing.strokes.count, 1)
        XCTAssertEqual(reopened.webView.bounds.width, 900, accuracy: 0.1)
        // Normal hit testing without a Pencil contact must reach the live page.
        XCTAssertFalse(reopened.canvas.isUserInteractionEnabled,
                       "The ink overlay must never block website hits")
        reopenedSession.drawsWithFinger = true
        reopened.updateTool()
        XCTAssertFalse(reopened.webView.scrollView.panGestureRecognizer.isEnabled,
                       "Optional finger ink must use hold-to-scroll instead of competing with native pan")
    }
}
