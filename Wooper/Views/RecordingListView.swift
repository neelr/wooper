import SwiftUI
import SwiftData
import Combine

struct RecordingListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Recording.date, order: .reverse) private var recordings: [Recording]
    private var recorder = AudioRecorderService.shared
    @State private var navigateToRecorder = false

    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()

                if recordings.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "waveform")
                            .font(.system(size: 48))
                            .foregroundStyle(.gray)
                        Text("No Recordings")
                            .font(.title3)
                            .foregroundStyle(.gray)
                        Text("Tap the record button to start")
                            .font(.subheadline)
                            .foregroundStyle(.gray.opacity(0.7))
                    }
                } else {
                    List {
                        ForEach(recordings) { recording in
                            NavigationLink(destination: PlaybackView(recording: recording)) {
                                RecordingRow(recording: recording)
                            }
                            .listRowBackground(Color(.systemGray6).opacity(0.15))
                        }
                        .onDelete(perform: deleteRecordings)
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }

                // Recording banner or record button
                VStack {
                    if recorder.isRecording && !navigateToRecorder {
                        Spacer()
                        HStack(spacing: 12) {
                            Circle()
                                .fill(.red)
                                .frame(width: 10, height: 10)
                            Text(formattedTime(recorder.elapsedTime))
                                .font(.headline.monospacedDigit())
                                .foregroundStyle(.white)
                            WaveformView(levels: recorder.audioLevels, barWidth: 2, barSpacing: 2, minBarHeight: 2)
                                .frame(height: 24)
                            Button {
                                stopFromIntent()
                            } label: {
                                Image(systemName: "stop.fill")
                                    .font(.callout)
                                    .foregroundStyle(.white)
                                    .padding(10)
                                    .background(.red, in: Circle())
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 14)
                        .background(.ultraThinMaterial.opacity(0.8))
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .padding(.horizontal, 16)
                        .padding(.bottom, 24)
                    } else {
                        Spacer()
                        Button {
                            navigateToRecorder = true
                        } label: {
                            ZStack {
                                Circle()
                                    .fill(.red)
                                    .frame(width: 64, height: 64)
                                Circle()
                                    .stroke(.white.opacity(0.3), lineWidth: 3)
                                    .frame(width: 72, height: 72)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("Wooper")
            .navigationDestination(isPresented: $navigateToRecorder) {
                RecorderView(recorder: recorder)
            }
            .toolbarColorScheme(.dark, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                        .foregroundStyle(.red)
                }
            }
        }
        .preferredColorScheme(.dark)
        .onReceive(NotificationCenter.default.publisher(for: .startRecordingIntent)) { _ in
            if !recorder.isRecording {
                recorder.startRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopRecordingFromWidget)) { _ in
            if recorder.isRecording {
                stopFromIntent()
            }
        }
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func stopFromIntent() {
        guard let (url, duration) = recorder.stopRecording() else { return }
        let recording = Recording(
            title: "New Recording",
            duration: duration,
            fileName: url.lastPathComponent
        )
        modelContext.insert(recording)

        Task {
            do {
                async let cdnUpload = CDNService.upload(fileURL: url)
                async let transcription = TranscriptionService.transcribe(url: url)

                let cdnURL = try await cdnUpload
                await MainActor.run { recording.cdnURL = cdnURL }

                let transcript = (try? await transcription) ?? ""
                if !transcript.isEmpty {
                    let autoTitle = (try? await ClaudeService.generateTitle(from: transcript)) ?? transcript.components(separatedBy: ".").first ?? "Voice Memo"
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

    private func deleteRecordings(at offsets: IndexSet) {
        for index in offsets {
            let recording = recordings[index]
            // Delete the audio file
            try? FileManager.default.removeItem(at: recording.fileURL)
            modelContext.delete(recording)
        }
    }
}

#Preview {
    RecordingListView()
        .modelContainer(for: Recording.self, inMemory: true)
}
