import PencilKit
import UIKit

struct WebPencilSample {
    var location: CGPoint
    var timestamp: TimeInterval
    var force: CGFloat
    var maximumForce: CGFloat
    var azimuth: CGFloat
    var altitude: CGFloat
}

/// Captures typed Pencil contacts at the common ancestor of web and ink views.
/// Hit testing happens before UIKit supplies UITouch.type on the Duo, so input
/// selection belongs here, not in a transparent overlay's hitTest method.
final class PencilScrollGesture: UIGestureRecognizer {
    private var intent = PencilScrollIntent()
    private var timer: Timer?
    private var holdAnchor = CGPoint.zero
    private(set) var origin = CGPoint.zero
    private(set) var position = CGPoint.zero
    private(set) var samples: [WebPencilSample] = []
    var isScrolling: Bool { intent.mode == .scroll }

    private func collect(_ touch: UITouch) {
        position = touch.location(in: view)
        if let last = samples.last, last.timestamp >= touch.timestamp { return }
        samples.append(WebPencilSample(location: position, timestamp: touch.timestamp,
                                       force: touch.force, maximumForce: touch.maximumPossibleForce,
                                       azimuth: touch.azimuthAngle(in: view), altitude: touch.altitudeAngle))
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard numberOfTouches <= 1, let touch = touches.first else {
            state = state == .began || state == .changed ? .cancelled : .failed
            return
        }
        collect(touch)
        origin = position
        intent.begin(at: origin, time: touch.timestamp)
        scheduleHold()
    }

    private func scheduleHold() {
        timer?.invalidate()
        holdAnchor = position
        let timer = Timer(timeInterval: PencilScrollIntent.holdDuration, repeats: false) { [weak self] _ in
            guard let self, self.state == .possible || self.state == .began || self.state == .changed else { return }
            if self.intent.hold() == .scroll { self.state = self.state == .possible ? .began : .changed }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = touches.first else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] {
            collect(sample)
            _ = intent.move(to: position, time: sample.timestamp)
        }
        if !intent.canBecomeScroll { timer?.invalidate() }
        else if hypot(position.x - holdAnchor.x, position.y - holdAnchor.y) > 2 { scheduleHold() }
        if state == .began || state == .changed { state = .changed; return }
        guard state == .possible else { return }
        if intent.mode != .waiting {
            if intent.mode == .scroll { timer?.invalidate() }
            state = .began
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        if let touch = touches.first { collect(touch) }
        // A short stationary tap is an ink dot; a held contact stays scrolling.
        state = .ended
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        timer?.invalidate()
        state = .cancelled
    }

    override func reset() {
        timer?.invalidate()
        timer = nil
        samples.removeAll(keepingCapacity: true)
        intent = PencilScrollIntent()
        super.reset()
    }
}

final class WebInkCanvas: PKCanvasView {
    private let inkUndoManager = UndoManager()
    override var undoManager: UndoManager? { inkUndoManager }
}

#if DEBUG
final class BrowserInputObserver: UIGestureRecognizer {
    var report: ((Set<UITouch>) -> Void)?
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { report?(touches) }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { report?(touches); state = .failed }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { report?(touches); state = .failed }
}
#endif
