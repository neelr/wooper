import SwiftUI
import SwiftData

@main
struct WooperApp: App {
    var body: some Scene {
        WindowGroup {
            RecordingListView()
        }
        .modelContainer(for: Recording.self)
    }
}
