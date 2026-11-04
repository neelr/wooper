import SwiftUI
import UIKit

@Observable @MainActor
final class StandbyTrigger {
    var policy = StandbyPolicy()
    var stacked = false
    var canPresent = true
    var keyboardVisible = false
    var visible: Bool { policy.visible }
}

/// Watches the real hinge and passively observes touches across the whole window,
/// including list scrolling and system menus; it never competes with their gestures.
@available(iOS 27.1, *)
struct StandbySensor: UIViewRepresentable {
    let trigger: StandbyTrigger
    func makeUIView(context: Context) -> SensorView { SensorView(trigger: trigger) }
    func updateUIView(_ view: SensorView, context: Context) { view.sample() }
    static func dismantleUIView(_ view: SensorView, coordinator: ()) { view.stop() }

    final class SensorView: UIView {
        let trigger: StandbyTrigger
        private var observer: TouchObserver?
        private var hinge: UIHingeInteraction?
        private var timer: Timer?
        private var notifications: [NSObjectProtocol] = []
        init(trigger: StandbyTrigger) {
            self.trigger = trigger
            super.init(frame: .zero)
            isUserInteractionEnabled = false
            for (name, visible) in [(UIResponder.keyboardWillShowNotification, true), (UIResponder.keyboardWillHideNotification, false)] {
                notifications.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor in
                        self?.trigger.keyboardVisible = visible
                        self?.trigger.policy.interact()
                    }
                })
            }
        }
        required init?(coder: NSCoder) { fatalError() }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if let hinge { hinge.view?.removeInteraction(hinge) }
            hinge = nil
            observer?.view?.removeGestureRecognizer(observer!)
            observer = nil
            timer?.invalidate()
            guard let window else { return }
            let hinge = UIHingeInteraction { [weak self] interaction, update in
                let partial = update.hinge?.status == .partiallyOpen
                DispatchQueue.main.async {
                    guard let self, interaction.view === self.window,
                          self.trigger.policy.partiallyOpen != partial else { return }
                    self.trigger.policy.hingeChanged(partial: partial)
                }
            }
            self.hinge = hinge
            window.addInteraction(hinge)
            let touch = TouchObserver { [weak self] touching in
                self?.trigger.policy.touching = touching
                self?.trigger.policy.interact()
            }
            window.addGestureRecognizer(touch)
            observer = touch
            timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in self?.sample() }
            sample()
        }
        func sample() {
            guard let window else { return }
            // Re-enabling requests UIKit's current hinge state. This also catches
            // folds whose live notification was lost during a hierarchy change.
            if window.windowScene?.activationState == .foregroundActive, let hinge {
                hinge.isEnabled = false
                hinge.isEnabled = true
            }
            let fixed = window.screen.fixedCoordinateSpace
            let origin = fixed.convert(CGPoint.zero, to: self)
            let axis = fixed.convert(CGPoint(x: 1, y: 0), to: self)
            let stacked = abs(axis.x - origin.x) > abs(axis.y - origin.y)
            // A system sheet, filter menu, or permissions prompt must not be covered.
            let canPresent = window.rootViewController?.presentedViewController == nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                if trigger.stacked != stacked { trigger.stacked = stacked }
                if trigger.canPresent != canPresent { trigger.canPresent = canPresent }
            }
        }
        func stop() {
            if let hinge { hinge.view?.removeInteraction(hinge) }
            hinge = nil
            observer?.view?.removeGestureRecognizer(observer!)
            observer = nil
            timer?.invalidate(); timer = nil
            notifications.forEach(NotificationCenter.default.removeObserver)
            notifications = []
        }
        deinit { timer?.invalidate(); notifications.forEach(NotificationCenter.default.removeObserver) }
    }

    final class TouchObserver: UIGestureRecognizer {
        private var touchesDown: Set<UITouch> = []
        let changed: (Bool) -> Void
        init(changed: @escaping (Bool) -> Void) {
            self.changed = changed
            super.init(target: nil, action: nil)
            cancelsTouchesInView = false
            delaysTouchesBegan = false
            delaysTouchesEnded = false
        }
        override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
        override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
            touchesDown.formUnion(touches); changed(true)
        }
        override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { changed(true) }
        override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
            touchesDown.subtract(touches); changed(!touchesDown.isEmpty)
            if touchesDown.isEmpty { state = .failed }
        }
        override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
            touchesDown.subtract(touches); changed(!touchesDown.isEmpty)
            if touchesDown.isEmpty { state = .failed }
        }
        override func reset() {
            // UIKit can reset a passive recognizer without any user interaction.
            // Only unfinished touches should affect the standby idle deadline.
            let wasTouching = !touchesDown.isEmpty
            touchesDown = []
            if wasTouching { changed(false) }
            super.reset()
        }
    }
}
