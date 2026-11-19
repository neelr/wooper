import Foundation

/// A hand touching during Pencil use stays rejected until it leaves the glass.
/// The grace period bridges the short lifts between handwritten strokes.
struct PencilPalmRejection<Contact: Hashable> {
    private var pencils = Set<Contact>()
    private var fingers = Set<Contact>()
    private var rejected = Set<Contact>()
    private var hovering = false
    private(set) var graceUntil: TimeInterval = 0

    var hasContacts: Bool { !pencils.isEmpty || !fingers.isEmpty }
    var hasPencilContact: Bool { !pencils.isEmpty }

    func blocksScrolling(at time: TimeInterval) -> Bool {
        hovering || !pencils.isEmpty || time < graceUntil || !rejected.isEmpty
    }

    mutating func beginPencil(_ contact: Contact) {
        pencils.insert(contact)
        rejected.formUnion(fingers)
    }

    mutating func endPencil(_ contact: Contact, at time: TimeInterval) {
        guard pencils.remove(contact) != nil else { return }
        graceUntil = time + 0.45
    }

    mutating func beginFinger(_ contact: Contact, at time: TimeInterval) {
        fingers.insert(contact)
        if blocksScrolling(at: time) { rejected.insert(contact) }
    }

    mutating func endFinger(_ contact: Contact) {
        fingers.remove(contact)
        rejected.remove(contact)
    }

    mutating func setHovering(_ active: Bool, at time: TimeInterval) {
        if active { rejected.formUnion(fingers) }
        else if hovering { graceUntil = time + 0.45 }
        hovering = active
    }
}
