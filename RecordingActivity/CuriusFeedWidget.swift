import SwiftUI
import WidgetKit
import AppIntents

private struct CuriusEntry: TimelineEntry {
    let date: Date
    let items: [CuriusFeedItem]
    var failed = false
    var offset = 0
    var hasMore = false
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
        completion(items.isEmpty ? placeholder(in: context) : makeEntry(items: items, family: context.family))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<CuriusEntry>) -> Void) {
        Task {
            let entry: CuriusEntry
            let defaults = UserDefaults.standard
            let cache = cached()
            let age = Date().timeIntervalSince1970 - defaults.double(forKey: "curius.widget.fetched")
            let offset = defaults.integer(forKey: CuriusPaging.offsetKey(CuriusPaging.size(context.family)))
            if !cache.isEmpty && (age < 1800 || offset > 0) {
                entry = makeEntry(items: cache, family: context.family)
            } else {
                do {
                    let page = try await PaperyService.curiusFeed(from: 0)
                    CuriusPaging.save(items: page.items, next: page.next)
                    defaults.set(Date().timeIntervalSince1970, forKey: "curius.widget.fetched")
                    entry = makeEntry(items: page.items, family: context.family)
                } catch {
                    entry = makeEntry(items: cache, family: context.family, failed: true)
                }
            }
            // WidgetKit controls the actual refresh schedule.
            completion(Timeline(entries: [entry], policy: .after(Date().addingTimeInterval(30 * 60))))
        }
    }

    private func cached() -> [CuriusFeedItem] { CuriusPaging.items() }

    private func makeEntry(items: [CuriusFeedItem], family: WidgetFamily, failed: Bool = false) -> CuriusEntry {
        let size = CuriusPaging.size(family)
        let offset = min(UserDefaults.standard.integer(forKey: CuriusPaging.offsetKey(size)), max(0, ((items.count - 1) / size) * size))
        return CuriusEntry(date: .now, items: items, failed: failed, offset: offset,
                           hasMore: offset + size < items.count || CuriusPaging.next() != nil)
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
    private var limit: Int { CuriusPaging.size(family) }
    private var visible: [CuriusFeedItem] { Array(entry.items.dropFirst(entry.offset).prefix(limit)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("curius").font(.system(size: 15, weight: .semibold, design: .monospaced))
                Spacer(minLength: 4)
                Button(intent: CuriusPageIntent(offset: max(0, entry.offset - limit), size: limit)) {
                    Image(systemName: "chevron.left").frame(width: 28, height: 36)
                }
                .disabled(entry.offset == 0)
                .accessibilityLabel("Previous stories")
                Button(intent: CuriusPageIntent(offset: entry.offset + limit, size: limit)) {
                    Image(systemName: "chevron.right").frame(width: 28, height: 36)
                }
                .disabled(!entry.hasMore)
                .accessibilityLabel("More stories")
            }
            if visible.isEmpty {
                Text(entry.failed ? "Feed unavailable. We'll try again soon." : "Nothing new in your feed.")
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(.secondary)
                    .frame(maxHeight: .infinity, alignment: .top)
            } else {
                VStack(alignment: .leading, spacing: family == .systemLarge ? 14 : 8) {
                    ForEach(Array(visible.enumerated()), id: \.offset) { index, item in
                        if family == .systemLarge && (index == 0 || visible[index - 1].day != item.day) {
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
        .buttonStyle(.plain)
        .tint(.secondary)
        .widgetURL(family == .systemSmall ? visible.first.flatMap { URL(string: $0.url) } : nil)
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


private enum CuriusPaging {
    static func size(_ family: WidgetFamily) -> Int { family == .systemLarge ? 4 : family == .systemMedium ? 2 : 1 }
    static func offsetKey(_ size: Int) -> String { "curius.widget.offset.\(size)" }
    static func items() -> [CuriusFeedItem] {
        guard let data = UserDefaults.standard.data(forKey: "curius.widget.feed") else { return [] }
        return (try? JSONDecoder().decode([CuriusFeedItem].self, from: data)) ?? []
    }
    static func next() -> Int? { UserDefaults.standard.object(forKey: "curius.widget.next") as? Int }
    static func save(items: [CuriusFeedItem], next: Int?) {
        if let data = try? JSONEncoder().encode(items) { UserDefaults.standard.set(data, forKey: "curius.widget.feed") }
        if let next { UserDefaults.standard.set(next, forKey: "curius.widget.next") }
        else { UserDefaults.standard.removeObject(forKey: "curius.widget.next") }
    }
}

struct CuriusPageIntent: AppIntent {
    static var title: LocalizedStringResource = "Browse Curius stories"
    static var openAppWhenRun = false
    @Parameter(title: "Offset") var offset: Int
    @Parameter(title: "Page size") var size: Int

    init() {}
    init(offset: Int, size: Int) { self.offset = offset; self.size = size }

    func perform() async throws -> some IntentResult {
        guard [1, 2, 4].contains(size), offset >= 0 else { return .result() }
        var items = CuriusPaging.items()
        // Fetch older links only when paging past the locally cached feed.
        var cursor = CuriusPaging.next()
        var attempts = 0
        while offset + size > items.count, let next = cursor, attempts < 3 {
            let page = try await PaperyService.curiusFeed(from: next)
            var known = Set(items.map(\.id))
            items.append(contentsOf: page.items.filter { known.insert($0.id).inserted })
            cursor = page.next == next ? nil : page.next
            attempts += 1
        }
        CuriusPaging.save(items: items, next: cursor)
        let last = max(0, ((items.count - 1) / size) * size)
        UserDefaults.standard.set(min(offset, last), forKey: CuriusPaging.offsetKey(size))
        WidgetCenter.shared.reloadTimelines(ofKind: "PaperyCuriusFeed")
        return .result()
    }
}
