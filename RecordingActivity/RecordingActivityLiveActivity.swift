import ActivityKit
import WidgetKit
import SwiftUI
import AppIntents

struct RecordingActivityLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: RecordingActivityAttributes.self) { context in
            lockScreenView(context: context)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(.red)
                            .frame(width: 8, height: 8)
                        Text(formattedTime(context.state.elapsedSeconds))
                            .font(.title3.monospacedDigit())
                            .foregroundStyle(.white)
                    }
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Button(intent: StopRecordingLiveIntent()) {
                        Image(systemName: "stop.fill")
                            .font(.caption)
                            .foregroundStyle(.white)
                            .padding(8)
                            .background(.red, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(context.state.transcriptionPreview.isEmpty ? "Listening…" : context.state.transcriptionPreview)
                        .font(.caption)
                        .foregroundStyle(.gray)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 4)
                        .padding(.top, 2)
                }
            } compactLeading: {
                Image("AppIcon")
                    .resizable()
                    .frame(width: 20, height: 20)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
            } compactTrailing: {
                HStack(spacing: 4) {
                    Circle()
                        .fill(.red)
                        .frame(width: 6, height: 6)
                    Text(formattedTime(context.state.elapsedSeconds))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white)
                }
            } minimal: {
                Image("AppIcon")
                    .resizable()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
        }
    }

    @ViewBuilder
    private func lockScreenView(context: ActivityViewContext<RecordingActivityAttributes>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle()
                    .fill(.red)
                    .frame(width: 10, height: 10)
                Text(formattedTime(context.state.elapsedSeconds))
                    .font(.headline.monospacedDigit())
                    .foregroundStyle(.white)
                Spacer()
                Button(intent: StopRecordingLiveIntent()) {
                    Image(systemName: "stop.fill")
                        .font(.callout)
                        .foregroundStyle(.white)
                        .padding(10)
                        .background(.red, in: Circle())
                }
                .buttonStyle(.plain)
            }
            Text(context.state.transcriptionPreview.isEmpty ? "Listening…" : context.state.transcriptionPreview)
                .font(.subheadline)
                .foregroundStyle(.gray)
                .lineLimit(2)
        }
        .padding()
        .background(.black)
    }

    private func formattedTime(_ seconds: Int) -> String {
        let m = seconds / 60
        let s = seconds % 60
        return String(format: "%d:%02d", m, s)
    }
}
