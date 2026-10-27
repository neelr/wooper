import SwiftUI

@MainActor @Observable
final class CuriusFeedStore {
    var items: [CuriusFeedItem] = []
    var loading = false
    var loaded = false
    var error: String?
    var next: Int? = 0
    var saving: Set<String> = []
    private var emptyPages = 0

    func load(refresh: Bool = false) async {
        guard !loading, refresh || next != nil else { return }
        loading = true
        error = nil
        defer { loading = false }
        let page = refresh ? 0 : next ?? 0
        do {
            let result = try await PaperyService.curiusFeed(from: page)
            guard !Task.isCancelled else { return }
            if refresh { items = []; emptyPages = 0 }
            var known = Set(items.map(\.url))
            let fresh = result.items.filter { known.insert($0.url).inserted }
            items.append(contentsOf: fresh)
            emptyPages = fresh.isEmpty ? emptyPages + 1 : 0
            next = emptyPages >= 2 || result.next == page ? nil : result.next
            loaded = true
        } catch {
            if !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func save(_ item: CuriusFeedItem) async {
        guard !item.saved, saving.insert(item.id).inserted else { return }
        defer { saving.remove(item.id) }
        do {
            try await PaperyService.save(url: item.url, title: item.title)
            if let index = items.firstIndex(where: { $0.id == item.id }) { items[index].saved = true }
            NotificationCenter.default.post(name: .paperyServerChanged, object: nil)
            Task { await PaperyCache.refresh() }
        } catch { self.error = error.localizedDescription }
    }
}

struct CuriusFeedView: View {
    @Bindable var store: CuriusFeedStore
    @Environment(\.openURL) private var openURL

    var body: some View {
        List {
            if let error = store.error {
                VStack(alignment: .leading, spacing: 8) {
                    Text(error).font(.caption).foregroundStyle(.secondary)
                    Button("Retry") { Task { await store.load(refresh: store.items.isEmpty) } }
                }
            }
            if store.loaded && store.items.isEmpty && store.error == nil {
                Text("Nothing new in your feed.").font(.subheadline).foregroundStyle(.secondary)
            }
            ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                VStack(alignment: .leading, spacing: 5) {
                    if index == 0 || store.items[index - 1].day != item.day {
                        Text(item.day.uppercased())
                            .font(.system(.caption2, design: .monospaced).weight(.semibold))
                            .foregroundStyle(.secondary).padding(.top, 8)
                    }
                    HStack(alignment: .top, spacing: 4) {
                        Button {
                            if let url = URL(string: item.url) { openURL(url) }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(item.title.isEmpty ? item.url : item.title)
                                    .font(.system(.subheadline, design: .monospaced)).lineLimit(2)
                                    .foregroundStyle(Color.paperyInk)
                                Text(item.metadata).font(.system(.caption2, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Button {
                            Task { await store.save(item) }
                        } label: {
                            Image(systemName: item.saved ? "checkmark" : "plus")
                                .frame(width: 44, height: 44)
                        }
                        .buttonStyle(.borderless)
                        .disabled(item.saved || store.saving.contains(item.id))
                        .accessibilityLabel(item.saved ? "Already in Papery" : "Save to Papery")
                    }
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 4))
                .listRowSeparatorTint(Color.paperyMeta.opacity(0.3))
                .listRowBackground(Color.paperyBg)
            }
            if store.loading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if store.next != nil && store.loaded {
                Button("Load older items") { Task { await store.load() } }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.paperyBg)
        .navigationTitle("curius")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { Task { await store.load(refresh: true) } } label: {
                    Label("Refresh feed", systemImage: "arrow.clockwise")
                }.disabled(store.loading)
            }
        }
        .refreshable { await store.load(refresh: true) }
        .task { if !store.loaded { await store.load() } }
    }
}
