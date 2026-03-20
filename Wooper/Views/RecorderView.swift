import SwiftUI

struct RecorderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Bindable var recorder: AudioRecorderService

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Elapsed time
            Text(formattedTime(recorder.elapsedTime))
                .font(.system(size: 64, weight: .thin, design: .monospaced))
                .foregroundStyle(.white)

            // Waveform
            WaveformView(levels: recorder.audioLevels)
                .frame(height: 100)
                .padding(.horizontal)

            Spacer()

            // Stop button
            Button {
                stopAndSave()
            } label: {
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 72, height: 72)

                    RoundedRectangle(cornerRadius: 6)
                        .fill(.white)
                        .frame(width: 28, height: 28)
                }
            }
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.black)
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    _ = recorder.stopRecording()
                    dismiss()
                }
                .foregroundStyle(.red)
            }
        }
        .onAppear {
            if !recorder.isRecording {
                recorder.startRecording()
            }
        }
    }

    private func stopAndSave() {
        guard let (url, duration) = recorder.stopRecording() else {
            dismiss()
            return
        }

        let recording = Recording(
            title: "New Recording",
            duration: duration,
            fileName: url.lastPathComponent
        )
        modelContext.insert(recording)
        dismiss()

        Task {
            do {
                async let cdnUpload = CDNService.upload(fileURL: url)
                async let transcription = TranscriptionService.transcribe(url: url)

                let cdnURL = try await cdnUpload
                await MainActor.run { recording.cdnURL = cdnURL }

                let transcript = (try? await transcription) ?? ""

                // Auto-title via Claude Haiku
                if !transcript.isEmpty {
                    let autoTitle = (try? await ClaudeService.generateTitle(from: transcript)) ?? transcript.components(separatedBy: ".").first ?? "Voice Memo"
                    await MainActor.run {
                        recording.title = autoTitle
                    }
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

    private func formattedTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let centiseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }
}
