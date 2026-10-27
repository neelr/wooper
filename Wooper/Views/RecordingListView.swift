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
                Color.paperyBg.ignoresSafeArea()

                if recordings.isEmpty {
                    VStack(spacing: 16) {
                        Image(systemName: "waveform")
                            .font(.system(size: 48))
                            .foregroundStyle(Color.paperyMeta)
                        Text("No Recordings")
                            .font(.system(.title3, design: .monospaced))
                            .foregroundStyle(Color.paperyMeta)
                        Text("Tap the record button to start")
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Color.paperyMeta.opacity(0.7))
                    }
                } else {
                    List {
                        ForEach(recordings) { recording in
                            NavigationLink(destination: PlaybackView(recording: recording)) {
                                RecordingRow(recording: recording)
                            }
                            .listRowBackground(Color.paperyBg)
                            .listRowSeparatorTint(Color.paperyMeta.opacity(0.3))
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
                                .font(.system(.headline, design: .monospaced).monospacedDigit())
                                .foregroundStyle(Color.paperyInk)
                            WaveformView(levels: recorder.audioLevels, barWidth: 2, barSpacing: 2, minBarHeight: 2)
                                .frame(height: 24)
                            Button {
                                RecordingProcessor.saveStoppedRecording(
                                    recorder: recorder,
                                    modelContext: modelContext
                                )
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
                        .background(.thinMaterial)
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
                                    .stroke(Color.paperyInk.opacity(0.15), lineWidth: 3)
                                    .frame(width: 72, height: 72)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                }
            }
            .navigationTitle("wooper")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbarBackground(Color.paperyBg, for: .navigationBar)
            .navigationDestination(isPresented: $navigateToRecorder) {
                RecorderView(recorder: recorder)
            }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .preferredColorScheme(.light)
        .tint(Color.paperyInk)
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
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
