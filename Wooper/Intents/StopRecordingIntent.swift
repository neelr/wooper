import AppIntents
import SwiftData

struct StopRecordingIntent: AppIntent {
    static var title: LocalizedStringResource = "Stop Recording"
    static var description: IntentDescription = "Stop the current Wooper recording"
    static var openAppWhenRun: Bool = false

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let savedTranscript = await MainActor.run { AudioRecorderService.shared.liveTranscript }
        let result = await MainActor.run {
            AudioRecorderService.shared.stopRecording()
        }

        guard let (url, duration) = result else {
            return .result(dialog: "No active recording.")
        }

        let container = try ModelContainer(for: Recording.self)
        let context = ModelContext(container)
        let fileName = url.lastPathComponent
        let recording = Recording(
            title: "New Recording",
            duration: duration,
            fileName: fileName
        )
        context.insert(recording)
        try context.save()

        Task.detached {
            do {
                let cdnURL = try await CDNService.upload(fileURL: url)
                let pipelineContext = ModelContext(container)
                let fetchFileName = fileName
                if let saved = try? pipelineContext.fetch(
                    FetchDescriptor<Recording>(predicate: #Predicate<Recording> { r in
                        r.fileName == fetchFileName
                    })
                ).first {
                    saved.cdnURL = cdnURL
                    try? pipelineContext.save()
                }

                // Use live transcript if available, fall back to file transcription
                let transcript: String
                if !savedTranscript.isEmpty {
                    transcript = savedTranscript
                } else {
                    transcript = (try? await TranscriptionService.transcribe(url: url)) ?? ""
                }

                var title = "New Recording"
                if !transcript.isEmpty {
                    title = (try? await ClaudeService.generateTitle(from: transcript)) ?? transcript.components(separatedBy: ".").first ?? "Voice Memo"
                    if let saved = try? pipelineContext.fetch(
                        FetchDescriptor<Recording>(predicate: #Predicate<Recording> { r in
                            r.fileName == fetchFileName
                        })
                    ).first {
                        saved.title = title
                        try? pipelineContext.save()
                    }
                }

                let notionURL = try await NotionService.createEntry(
                    title: title,
                    transcript: transcript,
                    audioURL: cdnURL
                )
                if let saved = try? pipelineContext.fetch(
                    FetchDescriptor<Recording>(predicate: #Predicate<Recording> { r in
                        r.fileName == fetchFileName
                    })
                ).first {
                    saved.notionURL = notionURL
                    try? pipelineContext.save()
                }
            } catch {
                print("Post-save pipeline failed: \(error)")
            }
        }

        return .result(dialog: "Recording saved.")
    }
}

extension Notification.Name {
    static let stopRecordingIntent = Notification.Name("stopRecordingIntent")
}
