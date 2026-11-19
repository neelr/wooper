import XCTest
import PencilKit
import WebKit
@testable import BrowserCheck

@MainActor final class BrowserCheckTests: XCTestCase {
    let url = URL(string: "https://example.com/article")!
    let fixture = "<html><head><meta name='viewport' content='width=device-width,initial-scale=1'></head><body style='margin:0'><h1>Article</h1><a href='https://example.com/next'>Next article</a><div style='height:6000px;background:linear-gradient(white,lightyellow)'>Long page</div></body></html>"

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
