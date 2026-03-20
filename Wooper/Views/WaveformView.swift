import SwiftUI

struct WaveformView: View {
    let levels: [CGFloat]
    var accentColor: Color = .red
    var barWidth: CGFloat = 3
    var barSpacing: CGFloat = 2
    var minBarHeight: CGFloat = 2

    var body: some View {
        GeometryReader { geometry in
            let totalBarWidth = barWidth + barSpacing
            let visibleBars = Int(geometry.size.width / totalBarWidth)
            let displayLevels = recentLevels(count: visibleBars)

            HStack(alignment: .center, spacing: barSpacing) {
                ForEach(Array(displayLevels.enumerated()), id: \.offset) { _, level in
                    RoundedRectangle(cornerRadius: barWidth / 2)
                        .fill(accentColor)
                        .frame(
                            width: barWidth,
                            height: max(minBarHeight, level * geometry.size.height)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        }
    }

    private func recentLevels(count: Int) -> [CGFloat] {
        if levels.count <= count {
            return levels
        }
        return Array(levels.suffix(count))
    }
}

#Preview {
    WaveformView(levels: (0..<50).map { _ in CGFloat.random(in: 0.1...1.0) })
        .frame(height: 80)
        .padding()
        .background(.black)
}
