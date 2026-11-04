import Foundation

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
