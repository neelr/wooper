import AppIntents

struct StartRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Start Recording"
    static var description: IntentDescription = "Start a new Wooper recording"
    static var openAppWhenRun: Bool = true

    func perform() async throws -> some IntentResult {
        await MainActor.run {
            NotificationCenter.default.post(name: .startRecordingIntent, object: nil)
        }
        return .result()
    }
}

extension Notification.Name {
    static let startRecordingIntent = Notification.Name("startRecordingIntent")
}
