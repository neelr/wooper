import PencilKit
import UIKit
import WebKit

/// The live web page and ink share document coordinates, scrolling, and zoom.
/// Only the viewport is rendered by PencilKit, including on very long articles.
final class WebBrowserController: UIViewController, WKNavigationDelegate, WKUIDelegate, PKCanvasViewDelegate {
    private let session: BrowserSession
    private let store: WebAnnotationStore
    private let page = UIView()
    let webView = WKWebView(frame: .zero)
    let canvas = WebInkCanvas()
    private lazy var pencilScroll = PencilScrollGesture(target: self, action: #selector(scrollWithPencil(_:)))
    private var observations: [NSKeyValueObservation] = []
    private var saveTask: Task<Void, Never>?
    private var activeURL: URL?
    private var annotationWidth: CGFloat?
    private var allowsAnnotations: Bool
    private var ready = false
    private var started = false
    private var restoring = false
    private var dirty = false
    private var savedDrawing = PKDrawing()
    private var annotationLoadFailed = false
    private var scrollOrigin = CGPoint.zero
    private var scrollingEnabledBeforeInk = true
    private var strokeBeforeEdit: PKDrawing?
    private var strokeStartOffset = CGPoint.zero
    private var strokeZoom: CGFloat = 1
    private var eraseSampleCount = 0
    private var appliedInk: BrowserSession.Ink?
    private var appliedRedInk: Bool?
    private var appliedFingerInk: Bool?
    #if DEBUG
    private var inputEvents: [[String: Any]] = []
    #endif

    init(session: BrowserSession, allowsAnnotations: Bool, store: WebAnnotationStore = WebAnnotationStore()) {
        self.session = session
        self.allowsAnnotations = allowsAnnotations
        self.store = store
        super.init(nibName: nil, bundle: nil)
        session.controller = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.992, green: 0.992, blue: 0.988, alpha: 1)
        view.clipsToBounds = true
        page.clipsToBounds = true
        view.addSubview(page)
        page.addSubview(webView)
        page.addSubview(canvas)
        canvas.isUserInteractionEnabled = false
        canvas.accessibilityElementsHidden = true
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.panGestureRecognizer.allowedTouchTypes = [
            NSNumber(value: UITouch.TouchType.direct.rawValue),
            NSNumber(value: UITouch.TouchType.indirect.rawValue),
            NSNumber(value: UITouch.TouchType.indirectPointer.rawValue)
        ]
        webView.isOpaque = false
        webView.backgroundColor = view.backgroundColor
        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.panGestureRecognizer.isEnabled = false
        canvas.pinchGestureRecognizer?.isEnabled = false
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.drawingGestureRecognizer.isEnabled = false
        page.addGestureRecognizer(pencilScroll)
        #if DEBUG
        let input = BrowserInputObserver()
        input.cancelsTouchesInView = false
        input.delaysTouchesBegan = false
        input.delaysTouchesEnded = false
        input.report = { [weak self] touches in
            guard let self else { return }
            let row: [String: Any] = [
                "time": Date().timeIntervalSince1970,
                "touches": touches.map { ["type": $0.type.rawValue, "phase": $0.phase.rawValue,
                                           "hitView": $0.view.map { String(describing: type(of: $0)) } ?? "nil"] as [String: Any] },
                "hidden": self.canvas.isHidden, "ready": self.ready,
                "enabled": self.canvas.drawingGestureRecognizer.isEnabled,
                "drawingState": self.strokeBeforeEdit == nil ? 0 : 1,
                "holdState": self.pencilScroll.state.rawValue,
                "strokes": self.canvas.drawing.strokes.count
            ]
            self.inputEvents.append(row)
            self.inputEvents = Array(self.inputEvents.suffix(12))
            if let data = try? JSONSerialization.data(withJSONObject: self.inputEvents, options: [.prettyPrinted]),
               let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                try? data.write(to: documents.appendingPathComponent("browser-input-debug.json"), options: .atomic)
            }
        }
        page.addGestureRecognizer(input)
        #endif
        updateTool()
        updateCanvasVisibility()
        observations = [
            webView.scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in self?.syncCanvas() },
            webView.scrollView.observe(\.contentSize, options: [.new]) { [weak self] _, _ in self?.syncCanvas() },
            webView.scrollView.observe(\.zoomScale, options: [.new]) { [weak self] _, _ in self?.syncCanvas() },
            webView.observe(\.url, options: [.new]) { [weak self] _, _ in
                // pushState / hash routing can change the document without a navigation callback.
                DispatchQueue.main.async { self?.urlChanged() }
            },
            webView.observe(\.canGoBack, options: [.new]) { [weak self] _, _ in self?.updateNavigation() },
            webView.observe(\.canGoForward, options: [.new]) { [weak self] _, _ in self?.updateNavigation() }
        ]
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        guard !started else { return }
        started = true
        webView.load(URLRequest(url: session.initialURL))
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        guard view.bounds.width > 0, view.bounds.height > 0 else { return }
        if allowsAnnotations && annotationWidth == nil { annotationWidth = max(200, view.bounds.width) }
        let width = allowsAnnotations ? (annotationWidth ?? view.bounds.width) : view.bounds.width
        let scale = view.bounds.width / width
        page.bounds = CGRect(x: 0, y: 0, width: width, height: view.bounds.height / scale)
        page.center = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
        page.transform = CGAffineTransform(scaleX: scale, y: scale)
        canvas.frame = page.bounds
        syncCanvas()
    }

    func setAnnotationsAvailable(_ available: Bool) {
        guard available != allowsAnnotations else { return }
        saveNow()
        allowsAnnotations = available
        // Cancel an in-flight gesture when the Duo changes screens.
        pencilScroll.isEnabled = false
        pencilScroll.isEnabled = available
        webView.scrollView.isScrollEnabled = true
        updateCanvasVisibility()
        view.setNeedsLayout()
    }

    func updateTool() {
        guard isViewLoaded else { return }
        if appliedInk != session.ink || appliedRedInk != session.redInk {
            switch session.ink {
            case .pen:
                canvas.tool = PKInkingTool(.pen, color: session.redInk ? .systemRed : UIColor(white: 0.08, alpha: 1), width: 2.5)
            case .highlighter:
                canvas.tool = PKInkingTool(.marker, color: (session.redInk ? UIColor.systemPink : .systemYellow).withAlphaComponent(0.4), width: 18)
            case .eraser: canvas.tool = PKEraserTool(.vector)
            }
            appliedInk = session.ink
            appliedRedInk = session.redInk
        }
        if appliedFingerInk != session.drawsWithFinger {
            pencilScroll.allowedTouchTypes = session.drawsWithFinger
                ? [NSNumber(value: UITouch.TouchType.pencil.rawValue), NSNumber(value: UITouch.TouchType.direct.rawValue)]
                : [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
            appliedFingerInk = session.drawsWithFinger
        }
        canvas.drawingGestureRecognizer.isEnabled = false
        webView.scrollView.panGestureRecognizer.isEnabled = strokeBeforeEdit == nil && !(session.drawsWithFinger && !canvas.isHidden)
    }

    private func syncCanvas() {
        guard isViewLoaded else { return }
        let scroll = webView.scrollView
        canvas.minimumZoomScale = min(scroll.minimumZoomScale, scroll.zoomScale)
        canvas.maximumZoomScale = max(scroll.maximumZoomScale, scroll.zoomScale)
        if abs(canvas.zoomScale - scroll.zoomScale) > 0.0001 { canvas.zoomScale = scroll.zoomScale }
        if canvas.contentSize != scroll.contentSize { canvas.contentSize = scroll.contentSize }
        if canvas.contentOffset != scroll.contentOffset { canvas.contentOffset = scroll.contentOffset }
        let webFrame = CGRect(origin: .zero, size: page.bounds.size)
        if webView.frame != webFrame { webView.frame = webFrame }
    }

    private func updateCanvasVisibility() {
        let showInk = allowsAnnotations && ready && !annotationLoadFailed && activeURL != nil
        canvas.isHidden = !showInk
        pencilScroll.isEnabled = showInk
        webView.scrollView.panGestureRecognizer.isEnabled = !(session.drawsWithFinger && showInk)
        syncCanvas()
    }

    @objc private func scrollWithPencil(_ gesture: PencilScrollGesture) {
        if !gesture.isScrolling {
            drawWithPencil(gesture)
            return
        }
        switch gesture.state {
        case .began:
            scrollOrigin = webView.scrollView.contentOffset
            UISelectionFeedbackGenerator().selectionChanged()
        case .changed:
            let scroll = webView.scrollView
            let maxX = max(0, scroll.contentSize.width - scroll.bounds.width)
            let maxY = max(0, scroll.contentSize.height - scroll.bounds.height)
            scroll.contentOffset = CGPoint(
                x: min(maxX, max(0, scrollOrigin.x + gesture.origin.x - gesture.position.x)),
                y: min(maxY, max(0, scrollOrigin.y + gesture.origin.y - gesture.position.y)))
        default: break
        }
    }

    private func drawWithPencil(_ gesture: PencilScrollGesture) {
        guard !gesture.samples.isEmpty else { return }
        if strokeBeforeEdit == nil {
            strokeBeforeEdit = canvas.drawing
            strokeStartOffset = webView.scrollView.contentOffset
            strokeZoom = max(0.01, webView.scrollView.zoomScale)
            eraseSampleCount = 0
            scrollingEnabledBeforeInk = webView.scrollView.isScrollEnabled
            webView.scrollView.isScrollEnabled = false
        }
        guard let original = strokeBeforeEdit else { return }
        func documentPoint(_ sample: WebPencilSample) -> CGPoint {
            CGPoint(x: (sample.location.x + strokeStartOffset.x) / strokeZoom,
                    y: (sample.location.y + strokeStartOffset.y) / strokeZoom)
        }
        restoring = true
        if session.ink == .eraser {
            let points = gesture.samples.dropFirst(max(0, eraseSampleCount - 1)).map(documentPoint)
            eraseSampleCount = gesture.samples.count
            let radius: CGFloat = 12 / strokeZoom
            canvas.drawing = PKDrawing(strokes: canvas.drawing.strokes.filter { stroke in
                !points.contains { point in
                    guard stroke.renderBounds.insetBy(dx: -radius, dy: -radius).contains(point) else { return false }
                    return stroke.path.interpolatedPoints(by: .distance(3)).contains { sample in
                        let p = sample.location.applying(stroke.transform)
                        return hypot(p.x - point.x, p.y - point.y) <= radius + sample.size.width / 2
                    }
                }
            })
        } else {
            let firstTime = gesture.samples[0].timestamp
            let marker = session.ink == .highlighter
            let points = gesture.samples.map { sample -> PKStrokePoint in
                let pressure = sample.maximumForce > 0 ? min(1.4, max(0.45, sample.force / sample.maximumForce * 2)) : 1
                let width: CGFloat = marker ? 18 : 2.5 * pressure
                return PKStrokePoint(location: documentPoint(sample), timeOffset: max(0, sample.timestamp - firstTime),
                                     size: CGSize(width: width, height: width), opacity: 1,
                                     force: sample.force, azimuth: sample.azimuth, altitude: sample.altitude)
            }
            let color: UIColor = marker
                ? (session.redInk ? UIColor.systemPink : .systemYellow).withAlphaComponent(0.4)
                : (session.redInk ? .systemRed : UIColor(white: 0.08, alpha: 1))
            let stroke = PKStroke(ink: PKInk(marker ? .marker : .pen, color: color),
                                  path: PKStrokePath(controlPoints: points, creationDate: Date()))
            canvas.drawing = PKDrawing(strokes: original.strokes + [stroke])
        }
        restoring = false
        if gesture.state == .ended || gesture.state == .cancelled {
            strokeBeforeEdit = nil
            webView.scrollView.isScrollEnabled = scrollingEnabledBeforeInk
            if canvas.drawing != original {
                canvas.undoManager?.registerUndo(withTarget: self) { target in target.replaceDrawing(original) }
                canvasViewDrawingDidChange(canvas)
            }
        }
    }

    private func replaceDrawing(_ drawing: PKDrawing) {
        let previous = canvas.drawing
        canvas.undoManager?.registerUndo(withTarget: self) { target in target.replaceDrawing(previous) }
        restoring = true
        canvas.drawing = drawing
        restoring = false
        canvasViewDrawingDidChange(canvas)
        updateUndo()
    }

    private func switchDocument(to url: URL) {
        guard WebAnnotationStore.accepts(url), activeURL.map(WebAnnotationStore.documentKey) != WebAnnotationStore.documentKey(url) else { return }
        guard saveNow() else {
            ready = false
            updateCanvasVisibility()
            return
        }
        saveTask?.cancel()
        activeURL = url
        dirty = false
        annotationLoadFailed = false
        restoring = true
        defer {
            savedDrawing = canvas.drawing
            restoring = false
            updateUndo()
            updateCanvasVisibility()
            view.setNeedsLayout()
        }
        canvas.drawing = PKDrawing()
        canvas.undoManager?.removeAllActions()
        annotationWidth = allowsAnnotations ? max(200, view.bounds.width) : nil
        session.saveStatus = ""
        do {
            if let saved = try store.load(url) {
                canvas.drawing = try PKDrawing(data: saved.drawing)
                annotationWidth = saved.pageWidth
                session.saveStatus = canvas.drawing.strokes.isEmpty ? "" : "saved on this device"
            }
        } catch {
            // Do not replace a damaged or newer-version document with an empty drawing.
            annotationLoadFailed = true
            session.message = "Saved annotations couldn’t be opened. The original file is unchanged."
        }
        canvas.undoManager?.removeAllActions()
    }

    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        scrollingEnabledBeforeInk = webView.scrollView.isScrollEnabled
        webView.scrollView.isScrollEnabled = false
    }

    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        webView.scrollView.isScrollEnabled = scrollingEnabledBeforeInk
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !restoring, strokeBeforeEdit == nil, !annotationLoadFailed, activeURL != nil, ready else { return }
        guard canvasView.drawing != savedDrawing else { return }
        dirty = true
        session.saveStatus = "saving…"
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.saveNow()
        }
        DispatchQueue.main.async { [weak self] in self?.updateUndo() }
    }

    @discardableResult func saveNow() -> Bool {
        saveTask?.cancel()
        saveTask = nil
        guard !annotationLoadFailed, !restoring, let url = activeURL else { return true }
        // PencilKit's delegate can arrive after a toolbar tap or scene change.
        // Compare the model too, so that last stroke is included immediately.
        if canvas.drawing != savedDrawing { dirty = true }
        guard dirty else { return true }
        guard let width = annotationWidth else { return false }
        do {
            let record = WebAnnotationRecord(url: WebAnnotationStore.documentKey(url), pageWidth: width,
                                             drawing: canvas.drawing.dataRepresentation())
            try store.save(record, for: url)
            savedDrawing = canvas.drawing
            dirty = false
            session.saveStatus = "saved on this device"
            return true
        } catch {
            session.saveStatus = "not saved"
            session.message = "Annotations couldn’t be saved. Please retry before closing this page."
            return false
        }
    }

    func undoInk() { canvas.undoManager?.undo(); updateUndo() }
    func redoInk() { canvas.undoManager?.redo(); updateUndo() }
    private func updateUndo() {
        session.canUndo = canvas.undoManager?.canUndo ?? false
        session.canRedo = canvas.undoManager?.canRedo ?? false
    }
    private func updateNavigation() {
        session.canGoBack = webView.canGoBack
        session.canGoForward = webView.canGoForward
    }
    private func urlChanged() {
        guard let url = webView.url else { return }
        session.url = url
        if !webView.isLoading && ready { switchDocument(to: url) }
    }
    func goBack() { if saveNow() { webView.goBack() } }
    func goForward() { if saveNow() { webView.goForward() } }
    func reload() {
        guard saveNow() else { return }
        if webView.url == nil { webView.load(URLRequest(url: session.url)) }
        else { webView.reload() }
    }
    func retry() {
        if dirty { saveNow(); if !dirty { session.message = nil }; return }
        if annotationLoadFailed, let url = activeURL {
            activeURL = nil
            session.message = nil
            switchDocument(to: url)
        } else { reload() }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let url = navigationAction.request.url else { decisionHandler(.cancel); return }
        if navigationAction.targetFrame?.isMainFrame != false, !saveNow() {
            decisionHandler(.cancel)
            return
        }
        if WebAnnotationStore.accepts(url) {
            if navigationAction.targetFrame == nil {
                decisionHandler(.cancel)
                saveNow()
                webView.load(navigationAction.request)
            } else {
                if navigationAction.targetFrame?.isMainFrame == true { saveNow() }
                decisionHandler(.allow)
            }
        } else if url.scheme == "about" || url.scheme == "blob" || url.scheme == "data" {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            // Only an explicit tap may hand a phone/mail/app link to the system.
            if navigationAction.navigationType == .linkActivated { UIApplication.shared.open(url) }
        }
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        saveNow()
        session.loading = true
        session.message = nil
        ready = false
        updateCanvasVisibility()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let url = webView.url, WebAnnotationStore.accepts(url) {
            switchDocument(to: url)
            session.url = url
        } else {
            // A generated PDF/blob/data page is a different document, never
            // an excuse to write its ink back onto the previous HTTP page.
            saveNow()
            activeURL = nil
            restoring = true
            canvas.drawing = PKDrawing()
            savedDrawing = canvas.drawing
            canvas.undoManager?.removeAllActions()
            restoring = false
            dirty = false
            session.saveStatus = ""
            updateCanvasVisibility()
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let url = webView.url { switchDocument(to: url); session.url = url }
        ready = true
        session.loading = false
        session.title = webView.title ?? ""
        updateNavigation()
        updateCanvasVisibility()
        syncCanvas()
    }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        ready = activeURL != nil
        session.loading = false
        session.message = "This page couldn’t load. Check your connection and retry."
        updateCanvasVisibility()
    }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        saveNow()
        ready = false
        session.loading = false
        session.message = "The page stopped responding. Your saved annotations are safe; retry to reopen it."
        updateCanvasVisibility()
    }
}
