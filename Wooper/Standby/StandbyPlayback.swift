import Foundation

/// The user's read-only Spotify endpoint reports the active Connect device.
/// Spotify's timestamp is the last playback-state change, not response freshness.
struct StandbyPlayback: Decodable {
    struct Device: Decodable { let name: String?; let type: String? }
    let song: String?
    let artist: String?
    let albumArt: String?
    let url: String?
    let playing: Bool?
    let device: Device?

    func isVisible(now: Date, receivedAt: Date?) -> Bool {
        guard playing == true, let song, !song.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let receivedAt else { return false }
        return now.timeIntervalSince(receivedAt) < 45
    }
}
