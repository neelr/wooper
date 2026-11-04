import Foundation

enum StandbyLayout {
    case expanded, tent

    static func resolve(isDuo: Bool, horizontalRegular: Bool, verticalRegular: Bool) -> Self? {
        guard isDuo else { return nil }
        if horizontalRegular && verticalRegular { return .expanded }
        // The outer display is compact in both dimensions in landscape.
        // Portrait phone use should remain on Papery, even with the hinge bent.
        if !horizontalRegular && !verticalRegular { return .tent }
        return nil
    }

    func supportsFold(partiallyOpen: Bool, angleDegrees: Double?, wasSupported: Bool) -> Bool {
        if self == .expanded { return partiallyOpen }
        // Duo may report .closed while the outside display is active in a
        // tent. The angle still measures the real bend (about 38° on-device).
        guard let angleDegrees, angleDegrees.isFinite else { return false }
        let range = wasSupported ? 10.0...160.0 : 15.0...150.0
        return range.contains(angleDegrees)
    }
}

/// Pure state machine so touches, folding, and scene transitions share one idle deadline.
struct StandbyPolicy {
    static let idleDelay: TimeInterval = 3
    private(set) var visible = false
    private(set) var partiallyOpen = false
    private(set) var suppressed = false
    private(set) var lastInteraction = Date()
    var touching = false

    mutating func hingeChanged(partial: Bool, now: Date = Date()) {
        guard partial != partiallyOpen else { return }
        partiallyOpen = partial
        suppressed = false
        visible = false
        lastInteraction = now
    }

    mutating func interact(now: Date = Date()) { lastInteraction = now }
    mutating func leave(now: Date = Date()) {
        visible = false
        touching = false
        lastInteraction = now
    }
    mutating func dismiss() { visible = false; suppressed = true }
    mutating func tick(eligible: Bool, now: Date = Date()) {
        guard eligible else { leave(now: now); return }
        if partiallyOpen && !suppressed && !touching && now.timeIntervalSince(lastInteraction) >= Self.idleDelay {
            visible = true
        }
    }
}

struct StandbyDeck {
    private var remaining: [Int] = []
    private var known: Set<Int> = []
    private(set) var current: Int?

    mutating func next(ids: [Int]) -> Int? {
        let available = Set(ids)
        guard !available.isEmpty else { current = nil; remaining = []; known = []; return nil }
        if available != known {
            remaining = Array(available.subtracting(current.map { [$0] } ?? [])).shuffled()
            known = available
        }
        if remaining.isEmpty {
            remaining = Array(available).shuffled()
            if remaining.count > 1, remaining.last == current { remaining.swapAt(0, remaining.count - 1) }
        }
        current = remaining.removeLast()
        return current
    }
}
