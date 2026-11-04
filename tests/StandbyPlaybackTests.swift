import Foundation

@main struct StandbyPlaybackTests {
    static func main() throws {
        let decoder = JSONDecoder()
        let now = Date(timeIntervalSince1970: 1000)
        func decode(_ text: String) throws -> StandbyPlayback {
            try decoder.decode(StandbyPlayback.self, from: Data(text.utf8))
        }
        let active = try decode(#"{"playing":true,"song":"Song","artist":"Artist","device":{"name":"Living room","type":"Speaker"},"timestamp":1}"#)
        assert(active.isVisible(now: now, receivedAt: now))
        assert(active.device?.name == "Living room")
        assert(!active.isVisible(now: now.addingTimeInterval(45), receivedAt: now))
        assert(!active.isVisible(now: now, receivedAt: nil))
        let paused = try decode(#"{"playing":false,"song":"Last song"}"#)
        assert(!paused.isVisible(now: now, receivedAt: now))
        let empty = try decode(#"{"playing":true,"song":null}"#)
        assert(!empty.isVisible(now: now, receivedAt: now))
        let unavailable = try decode(#"{}"#)
        assert(!unavailable.isVisible(now: now, receivedAt: now))
        print("PASS active-device metadata, paused/empty responses, and stale playback expiry")
    }
}
