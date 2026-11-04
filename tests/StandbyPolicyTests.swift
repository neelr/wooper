import Foundation

@main struct StandbyPolicyTests {
    static func main() {
        let start = Date(timeIntervalSince1970: 10000)
        var gate = StandbyPolicy()
        gate.hingeChanged(partial: true, now: start)
        var freshFold = gate
        freshFold.tick(eligible: true, now: start.addingTimeInterval(3))
        assert(freshFold.visible, "A fresh fold enters standby after three idle seconds")
        gate.tick(eligible: true, now: start.addingTimeInterval(2))
        assert(!gate.visible)
        gate.interact(now: start.addingTimeInterval(2))
        gate.tick(eligible: true, now: start.addingTimeInterval(3))
        assert(!gate.visible, "Scrolling must reset the countdown")
        gate.touching = true
        gate.tick(eligible: true, now: start.addingTimeInterval(40))
        assert(!gate.visible, "A held touch must prevent entry")
        gate.touching = false
        gate.tick(eligible: true, now: start.addingTimeInterval(41))
        assert(gate.visible)
        gate.dismiss()
        gate.tick(eligible: true, now: start.addingTimeInterval(100))
        assert(!gate.visible, "Manual exit suppresses entry until another fold")
        gate.hingeChanged(partial: false, now: start.addingTimeInterval(101))
        gate.hingeChanged(partial: true, now: start.addingTimeInterval(102))
        gate.tick(eligible: false, now: start.addingTimeInterval(120))
        assert(!gate.visible, "DS, books, background, keyboard, and sheets are ineligible")
        gate.tick(eligible: true, now: start.addingTimeInterval(122))
        assert(!gate.visible)
        gate.tick(eligible: true, now: start.addingTimeInterval(123))
        assert(gate.visible)
        gate.hingeChanged(partial: false)
        assert(!gate.visible, "Opening flat or closing exits immediately")
        var deck = StandbyDeck()
        assert(deck.next(ids: []) == nil)
        assert(deck.next(ids: [7]) == 7 && deck.next(ids: [7]) == 7)
        deck = StandbyDeck()
        let ids = Array(1...10)
        var previous: Int?
        for _ in 0..<20 {
            var cycle = Set<Int>()
            for _ in ids {
                let id = deck.next(ids: ids)!
                assert(id != previous, "No consecutive repeats across cycle boundaries")
                assert(cycle.insert(id).inserted)
                previous = id
            }
        }
        assert(deck.next(ids: [999]) == 999, "Removed/read papers must leave the deck")
        print("PASS standby idle, folding, interaction, suppression, eligibility, and shuffle cycles")
    }
}
