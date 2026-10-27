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
                .foregroundStyle(Color.paperyInk)

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
        .background(Color.paperyBg.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button("Cancel") {
                    _ = recorder.stopRecording()
                    dismiss()
                }
                .foregroundStyle(Color.paperyMeta)
            }
        }
        .onAppear {
            if !recorder.isRecording {
                recorder.startRecording()
            }
        }
    }

    private func stopAndSave() {
        RecordingProcessor.saveStoppedRecording(
            recorder: recorder,
            modelContext: modelContext
        )
        dismiss()
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        let centiseconds = Int((time.truncatingRemainder(dividingBy: 1)) * 100)
        return String(format: "%02d:%02d.%02d", minutes, seconds, centiseconds)
    }
}
