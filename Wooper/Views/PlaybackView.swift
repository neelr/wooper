import SwiftUI

struct PlaybackView: View {
    let recording: Recording
    @State private var player = AudioPlayerService()
    @State private var editableTitle: String = ""
    @State private var isScrubbing = false
    @State private var scrubTime: TimeInterval = 0
    @Environment(\.modelContext) private var modelContext

    private var displayTime: TimeInterval {
        isScrubbing ? scrubTime : player.currentTime
    }

    private var progress: Double {
        player.duration > 0 ? displayTime / player.duration : 0
    }

    var body: some View {
        VStack(spacing: 20) {
            // Title
            TextField("Recording Name", text: $editableTitle)
                .font(.system(.title2, design: .monospaced).bold())
                .foregroundStyle(Color.paperyInk)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
                .onSubmit {
                    recording.title = editableTitle
                }

            // Date + Duration
            Text("\(recording.date.formatted(date: .long, time: .shortened)) • \(formattedDuration(recording.duration))")
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(Color.paperyMeta)

            Spacer()

            // Waveform scrubber
            ScrubWaveformView(
                levels: player.waveformSamples,
                progress: progress,
                onScrub: { fraction in
                    isScrubbing = true
                    scrubTime = player.duration * fraction
                },
                onScrubEnd: { fraction in
                    let time = player.duration * fraction
                    player.seek(to: time)
                    isScrubbing = false
                }
            )
            .frame(height: 140)
            .padding(.horizontal, 16)

            // Time labels
            HStack {
                Text(formattedTime(displayTime))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.paperyInk)
                Spacer()
                Text("-\(formattedTime(max(0, player.duration - displayTime)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.paperyMeta)
            }
            .padding(.horizontal, 16)

            Spacer()

            // Playback controls
            HStack(spacing: 48) {
                Button {
                    player.seek(to: max(0, player.currentTime - 15))
                } label: {
                    Image(systemName: "gobackward.15")
                        .font(.title)
                        .foregroundStyle(Color.paperyInk)
                }

                Button {
                    player.togglePlayback()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 64))
                        .foregroundStyle(Color.paperyInk)
                }

                Button {
                    player.seek(to: min(player.duration, player.currentTime + 15))
                } label: {
                    Image(systemName: "goforward.15")
                        .font(.title)
                        .foregroundStyle(Color.paperyInk)
                }
            }
            .padding(.bottom, 48)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.paperyBg.ignoresSafeArea())
        .onAppear {
            editableTitle = recording.title
            player.loadAudio(url: recording.fileURL)
        }
        .onDisappear {
            player.stop()
            recording.title = editableTitle
        }
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func formattedTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - Scrubbing Waveform

struct ScrubWaveformView: View {
    let levels: [CGFloat]
    let progress: Double
    var onScrub: (Double) -> Void
    var onScrubEnd: (Double) -> Void

    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let totalBarWidth = barWidth + barSpacing
            let barCount = Int(geometry.size.width / totalBarWidth)
            let displayLevels = resample(to: barCount)
            let playheadX = progress * geometry.size.width

            ZStack(alignment: .leading) {
                // Waveform bars
                HStack(alignment: .center, spacing: barSpacing) {
                    ForEach(Array(displayLevels.enumerated()), id: \.offset) { index, level in
                        let barX = Double(index) / Double(max(1, barCount - 1))
                        RoundedRectangle(cornerRadius: barWidth / 2)
                            .fill(barX <= progress ? Color.paperyInk : Color.paperyMeta.opacity(0.35))
                            .frame(
                                width: barWidth,
                                height: max(2, level * geometry.size.height * 0.9)
                            )
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)

                // Playhead
                Rectangle()
                    .fill(Color.paperyInk)
                    .frame(width: 2, height: geometry.size.height)
                    .offset(x: playheadX - 1)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / geometry.size.width))
                        onScrub(fraction)
                    }
                    .onEnded { value in
                        let fraction = max(0, min(1, value.location.x / geometry.size.width))
                        onScrubEnd(fraction)
                    }
            )
        }
    }

    private func resample(to count: Int) -> [CGFloat] {
        guard !levels.isEmpty, count > 0 else {
            return Array(repeating: 0.15, count: max(1, count))
        }
        if levels.count == count { return levels }
        return (0..<count).map { i in
            let src = Double(i) / Double(count) * Double(levels.count)
            let idx = min(Int(src), levels.count - 1)
            return levels[idx]
        }
    }
}
