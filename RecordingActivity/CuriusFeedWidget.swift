import SwiftUI
import WidgetKit

private struct CuriusEntry: TimelineEntry {
    let date: Date
    let items: [CuriusFeedItem]
    var failed = false
}

private struct CuriusProvider: TimelineProvider {
    private let cacheKey = "curius.widget.feed"

    func placeholder(in context: Context) -> CuriusEntry {
        CuriusEntry(date: .now, items: [
            CuriusFeedItem(url: "https://curius.app", title: "A good read from your corner of the internet", metadata: "someone you follow", day: "today", saved: false),
            CuriusFeedItem(url: "https://curius.app/explore", title: "Notes, ideas, and things worth keeping", metadata: "from your curius feed", day: "today", saved: false)
        ])
    }

    func getSnapshot(in context: Context, completion: @escaping (CuriusEntry) -> Void) {
        let items = cached()
        completion(items.isEmpty ? placeholder(in: context) : CuriusEntry(date: .now, items: items))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CuriusEntry>) -> Void) {
        Task {
            let entry: CuriusEntry
            do {
                let page = try await PaperyService.curiusFeed(from: 0)
                let items = Array(page.items.prefix(12))
                if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: cacheKey) }
                entry = CuriusEntry(date: .now, items: items)
            } catch {
                entry = CuriusEntry(date: .now, items: cached(), failed: true)
            }
            // WidgetKit controls the actual refresh schedule.
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }

    private func cached() -> [CuriusFeedItem] {
        guard let data = UserDefaults.standard.data(forKey: cacheKey) else { return [] }
        return (try? JSONDecoder().decode([CuriusFeedItem].self, from: data)) ?? []
    }
}

struct CuriusFeedWidget: Widget {
    let kind = "PaperyCuriusFeed"
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: kind, provider: CuriusProvider()) { entry in
            CuriusWidgetView(entry: entry)
                .containerBackground(.background, for: .widget)
        }
        .configurationDisplayName("papery · curius")
        .description("Recent links from your Curius feed. Tap a story to read it.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

private struct CuriusWidgetView: View {
    let entry: CuriusEntry
    @Environment(\.widgetFamily) private var family
    private var limit: Int { family == .systemLarge ? 5 : family == .systemMedium ? 3 : 2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("curius").font(.system(size: 15, weight: .semibold, design: .monospaced))
                Spacer(minLength: 4)
                Text("papery").font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
            }
            if entry.items.isEmpty {
                Text(entry.failed ? "Feed unavailable. We'll try again soon." : "Nothing new in your feed.")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 14 : 8) {
                    ForEach(Array(entry.items.prefix(limit).enumerated()), id: \.offset) { index, item in
                        if family == .systemLarge && (index == 0 || entry.items[index - 1].day != item.day) {
                            Text(item.day).font(.system(size: 10, design: .monospaced)).foregroundStyle(.tertiary)
                        }
                        if family == .systemSmall {
                            row(item)
                        } else if let url = URL(string: item.url) {
                            Link(destination: url) { row(item) }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(family == .systemSmall ? entry.items.first.flatMap { URL(string: $0.url) } : nil)
    }

    private func row(_ item: CuriusFeedItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title.isEmpty ? item.url : item.title)
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(family == .systemMedium ? 1 : 2)
            Text(item.metadata)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
