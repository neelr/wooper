import AppIntents
import Foundation

struct StopRecordingLiveIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var description: IntentDescription = "Stop the current Wooper recording"

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .stopRecordingFromWidget, object: nil)
        }
        return .result()
    }
}

extension Notification.Name {
    static let stopRecordingFromWidget = Notification.Name("stopRecordingFromWidget")
}
