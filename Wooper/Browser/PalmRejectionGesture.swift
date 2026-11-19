import UIKit

/// Passive tracking: it neither claims touches nor competes with web/Pencil
/// gestures. Unlike an exclusive recognizer, it sees hand and Pencil together.
final class PalmRejectionGesture: UIGestureRecognizer {
    private var policy = PencilPalmRejection<ObjectIdentifier>()
    private var releaseTimer: Timer?
    private(set) var blocksScrolling = false
    var hasPencilContact: Bool { policy.hasPencilContact }
    var onChange: (() -> Void)?

    override init(target: Any?, action: Selector?) {
        super.init(target: target, action: action)
        allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue),
                             NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        requiresExclusiveTouchType = false
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        // Process Pencil first when both arrive in the same event.
        for touch in touches where touch.type == .pencil { policy.beginPencil(ObjectIdentifier(touch)) }
        for touch in touches where touch.type == .direct {
            policy.beginFinger(ObjectIdentifier(touch), at: ProcessInfo.processInfo.systemUptime)
        }
        publish()
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { finish(touches) }

    private func finish(_ touches: Set<UITouch>) {
        for touch in touches {
            let id = ObjectIdentifier(touch)
            if touch.type == .pencil { policy.endPencil(id, at: ProcessInfo.processInfo.systemUptime) }
            else { policy.endFinger(id) }
        }
        publish()
        if !policy.hasContacts { state = .failed }
    }

    func setPencilHovering(_ active: Bool) {
        policy.setHovering(active, at: ProcessInfo.processInfo.systemUptime)
        publish()
    }

    func clearTracking() {
        policy = PencilPalmRejection()
        publish()
    }

    private func publish() {
        let now = ProcessInfo.processInfo.systemUptime
        let blocked = policy.blocksScrolling(at: now)
        if blocked != blocksScrolling {
            blocksScrolling = blocked
            onChange?()
        }
        releaseTimer?.invalidate()
        releaseTimer = nil
        if policy.graceUntil > now {
            let timer = Timer(timeInterval: policy.graceUntil - now, repeats: false) { [weak self] _ in self?.publish() }
            releaseTimer = timer
            RunLoop.main.add(timer, forMode: .common)
        }
    }
}

final class PencilHoverGesture: UIHoverGestureRecognizer {
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
}
