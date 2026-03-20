import SwiftUI

struct RecordingRow: View {
    let recording: Recording
    @Environment(\.openURL) private var openURL

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(recording.title)
                    .font(.headline)
                    .foregroundStyle(.white)

                HStack(spacing: 12) {
                    Text(recording.date.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.gray)

                    Text(formattedDuration(recording.duration))
                        .font(.caption)
                        .foregroundStyle(.gray)
                }
            }

            Spacer()

            if let notionURL = recording.notionURL, let url = URL(string: notionURL) {
                Button {
                    openURL(url)
                } label: {
                    Image(systemName: "note.text")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
            }

            if recording.cdnURL != nil {
                Image(systemName: "cloud.fill")
                    .font(.caption)
                    .foregroundStyle(.green.opacity(0.6))
            } else {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .padding(.vertical, 4)
    }

    private func formattedDuration(_ duration: TimeInterval) -> String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
