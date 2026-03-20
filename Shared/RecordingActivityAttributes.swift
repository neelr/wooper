import ActivityKit
import Foundation

struct RecordingActivityAttributes: ActivityAttributes {
    public struct ContentState: Codable, Hashable {
        var elapsedSeconds: Int
        var isRecording: Bool
        var waveformLevels: [Float]
        var transcriptionPreview: String
    }

    var recordingTitle: String
}
