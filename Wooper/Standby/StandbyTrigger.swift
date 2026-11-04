import SwiftUI
import UIKit

@Observable @MainActor
final class StandbyTrigger {
    var policy = StandbyPolicy()
    var stacked = false
    var canPresent = true
    var keyboardVisible = false
    var visible: Bool { policy.visible }

    #if DEBUG
    @ObservationIgnored var hingeStatus = "no update"
    @ObservationIgnored var hingeAngle: Double?
    @ObservationIgnored var hingeUpdates = 0
    @ObservationIgnored var hingeTransitions: [[String: Any]] = []
    @ObservationIgnored var eligible = false
    #endif

    @available(iOS 27.1, *)
    func hingeChanged(_ hinge: DeviceHinge?) {
        #if DEBUG
        let status: String
        switch hinge?.status {
        case .closed: status = "closed"
        case .partiallyOpen: status = "partially open"
        case .fullyOpen: status = "fully open"
        default: status = "unavailable"
        }
        if status != hingeStatus {
            hingeTransitions.append(["status": status, "time": Date().timeIntervalSince1970])
            hingeTransitions = Array(hingeTransitions.suffix(20))
        }
        hingeStatus = status
        hingeAngle = hinge?.angle.degrees
        hingeUpdates += 1
        #endif
        let partial = hinge?.status == .partiallyOpen
        if policy.partiallyOpen != partial { policy.hingeChanged(partial: partial) }
    }
}

/// Attach to the persistent SwiftUI content, including the standby overlay, so
/// folding remains observable while either screen is visible.
struct StandbyHingeObserver: ViewModifier {
    let trigger: StandbyTrigger
    let enabled: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27.1, *) {
            content.onHingeChange(isEnabled: enabled) { _, context in
                trigger.hingeChanged(context.hinge)
            }
        } else {
            content
        }
    }
}

/// Samples layout and passively observes touches across the whole window,
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
        private var timer: Timer?
        #if DEBUG
        private var lastDiagnostic = Date.distantPast
        #endif
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
            observer?.view?.removeGestureRecognizer(observer!)
            observer = nil
            timer?.invalidate()
            guard let window else { return }
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
                #if DEBUG
                if Date().timeIntervalSince(lastDiagnostic) > 2 {
                    lastDiagnostic = Date()
                    let fields: [String: Any] = [
                        "time": Date().timeIntervalSince1970,
                        "hinge": trigger.hingeStatus, "angleDegrees": trigger.hingeAngle as Any? ?? NSNull(),
                        "hingeUpdates": trigger.hingeUpdates, "transitions": trigger.hingeTransitions,
                        "partial": trigger.policy.partiallyOpen, "visible": trigger.visible,
                        "eligible": trigger.eligible,
                        "touching": trigger.policy.touching, "suppressed": trigger.policy.suppressed,
                        "idle": Date().timeIntervalSince(trigger.policy.lastInteraction),
                        "canPresent": canPresent, "keyboard": trigger.keyboardVisible,
                        "active": window.windowScene?.activationState == .foregroundActive
                    ]
                    if let data = try? JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys]),
                       let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first {
                        try? data.write(to: directory.appendingPathComponent("standby-debug.json"), options: .atomic)
                    }
                }
                #endif
            }
        }
        func stop() {
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
