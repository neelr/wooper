import Foundation
import SwiftData

/// The shared "stop recording, then upload + transcribe + title + save to
/// Notion" pipeline. Extracted so it can run from anywhere the recording is
/// stopped — the in-app recorder screen and the Live Activity / widget stop
/// intent (which now fires at the app root, not a specific screen).
enum RecordingProcessor {
    @MainActor
    static func saveStoppedRecording(
        recorder: AudioRecorderService,
        modelContext: ModelContext
    ) {
        let savedTranscript = recorder.liveTranscript
        guard let (url, duration) = recorder.stopRecording() else { return }

        let recording = Recording(
            title: "New Recording",
            duration: duration,
            fileName: url.lastPathComponent
        )
        modelContext.insert(recording)

        Task {
            do {
                let cdnURL = try await CDNService.upload(fileURL: url)
                await MainActor.run { recording.cdnURL = cdnURL }

                let transcript: String
                if !savedTranscript.isEmpty {
                    transcript = savedTranscript
                } else {
                    transcript = (try? await TranscriptionService.transcribe(url: url)) ?? ""
                }

                if !transcript.isEmpty {
                    let autoTitle = (try? await ClaudeService.generateTitle(from: transcript))
                        ?? transcript.components(separatedBy: ".").first
                        ?? "Voice Memo"
                    await MainActor.run { recording.title = autoTitle }
                }

                let notionURL = try await NotionService.createEntry(
                    title: recording.title,
                    transcript: transcript,
                    audioURL: cdnURL
                )
                await MainActor.run { recording.notionURL = notionURL }
            } catch {
                print("Post-save pipeline failed: \(error)")
            }
        }
    }
}
