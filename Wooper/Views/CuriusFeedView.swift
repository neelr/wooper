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
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
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
                            Text(item.day)
                                .font(.caption)
                                .foregroundStyle(.tertiary).padding(.top, index == 0 ? 0 : 12)
                        }
                        HStack(alignment: .top, spacing: 4) {
                            Button {
                                if let url = URL(string: item.url) { openURL(url) }
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title.isEmpty ? item.url : item.title)
                                        .font(horizontalSizeClass == .regular ? .body : .subheadline).lineLimit(3)
                                        .foregroundStyle(Color.paperyInk)
                                    Text(item.metadata).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            Button {
                                Task { await store.save(item) }
                            } label: {
                                Image(systemName: item.saved ? "checkmark" : "plus")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(.borderless)
                            .disabled(item.saved || store.saving.contains(item.id))
                            .accessibilityLabel(item.saved ? "Already in Papery" : "Save to Papery")
                        }
                    }
                }
                if store.loaded, let next = store.next, store.error == nil {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .task(id: next) { await store.load() }
                } else if store.loading {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
        }
        .background(Color.paperyBg)
        .navigationTitle("curius")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await store.load(refresh: true) }
        .task { if !store.loaded { await store.load() } }
    }
}
