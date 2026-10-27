import SwiftUI

enum PaperyFilter: String, CaseIterable, Identifiable {
    case unread, all, liked
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unread: return "Unread"
        case .all: return "All"
        case .liked: return "Liked"
        }
    }
    /// The `read` query value this filter maps to.
    var readParam: String { self == .unread ? "unread" : "all" }
    var likedOnly: Bool { self == .liked }
}

@Observable
final class PaperyStore {
    var papers: [Paper] = []
    var query: String = ""
    var filter: PaperyFilter = .unread
    var isLoading = false
    var errorMessage: String?
    var loadedOnce = false

    @MainActor
    func load() async {
        isLoading = true
        errorMessage = nil
        do {
            papers = try await PaperyService.list(
                read: filter.readParam,
                liked: filter.likedOnly,
                query: query
            )
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
        loadedOnce = true
    }

    // Optimistic mutations, then reconcile with the server.

    /// Every mutation changes server state the reader cares about; refreshing
    /// the lens cache detects that and nudges a BLE sync, without waiting for
    /// the (throttle-prone) push echo back to this same phone.
    private func nudgeReader() {
        Task.detached { await PaperyCache.refresh() }
    }

    @MainActor
    func toggleRead(_ paper: Paper) async {
        try? await PaperyService.toggleRead(id: paper.id)
        await load()
        nudgeReader()
    }

    @MainActor
    func toggleLike(_ paper: Paper) async {
        try? await PaperyService.toggleLike(id: paper.id)
        await load()
        nudgeReader()
    }

    @MainActor
    func delete(_ paper: Paper) async {
        papers.removeAll { $0.id == paper.id }
        try? await PaperyService.delete(id: paper.id)
        nudgeReader()
    }

    /// Reorder locally, then persist the moved paper's new neighbours.
    @MainActor
    func move(from source: IndexSet, to destination: Int) {
        guard let first = source.first, papers.indices.contains(first) else { return }
        let movingId = papers[first].id
        papers.move(fromOffsets: source, toOffset: destination)
        guard let idx = papers.firstIndex(where: { $0.id == movingId }) else { return }
        let prev = idx > 0 ? papers[idx - 1].id : nil
        let next = idx < papers.count - 1 ? papers[idx + 1].id : nil
        Task { try? await PaperyService.move(id: movingId, prev: prev, next: next) }
    }
}

struct PaperyListView: View {
    var largePreviews = false
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var store = PaperyStore()
    @State private var feed = CuriusFeedStore()
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    @Environment(\.openURL) private var openURL

    var body: some View {
        Group {
            if largePreviews && horizontalSizeClass == .regular {
                NavigationSplitView(columnVisibility: $columnVisibility) {
                    CuriusFeedView(store: feed)
                        .toolbar(removing: .sidebarToggle)
                        .navigationSplitViewColumnWidth(min: 240, ideal: 320, max: 380)
                } detail: {
                    readingList
                }
                .navigationSplitViewStyle(.balanced)
            } else {
                readingList
            }
        }
    }

    private var readingList: some View {
        NavigationStack {
            Group {
                if let error = store.errorMessage, store.papers.isEmpty {
                    ContentUnavailableView {
                        Label("Couldn't load", systemImage: "wifi.exclamationmark")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") { Task { await store.load() } }
                    }
                } else if store.papers.isEmpty && store.loadedOnce {
                    ContentUnavailableView(
                        store.filter == .liked ? "No liked papers" : "Nothing here",
                        systemImage: store.filter == .liked ? "heart" : "books.vertical"
                    )
                } else {
                    listContent
                }
            }
            .background(Color.paperyBg.ignoresSafeArea())
            .navigationTitle("papery")
            .toolbarTitleDisplayMode(.inlineLarge)
            .toolbarBackground(Color.paperyBg, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    EditButton()
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Compact, standard filter affordance: an icon menu that
                    // fills in when a non-default filter is active.
                    Menu {
                        Picker("Filter", selection: $store.filter) {
                            ForEach(PaperyFilter.allCases) { f in
                                Text(f.label).tag(f)
                            }
                        }
                    } label: {
                        Label("Filter", systemImage: store.filter == .unread
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                LensStatusBar()
            }
            .searchable(text: $store.query, prompt: "search")
            .onChange(of: store.filter) { _, _ in Task { await store.load() } }
            .onSubmit(of: .search) { Task { await store.load() } }
            .onChange(of: store.query) { _, newValue in
                if newValue.isEmpty { Task { await store.load() } }
            }
            .onReceive(NotificationCenter.default.publisher(for: .paperyServerChanged).receive(on: DispatchQueue.main)) { _ in
                Task { await store.load() }
            }
        }
        .preferredColorScheme(.light)
        .tint(Color.paperyInk)
        .task {
            if !store.loadedOnce { await store.load() }
        }
    }

    private var listContent: some View {
        List {
            ForEach(store.papers) { paper in
                HStack(spacing: 8) {
                    Button {
                        if let url = URL(string: paper.url) { openURL(url) }
                    } label: {
                        PaperRow(paper: paper, roomyPreview: largePreviews && horizontalSizeClass == .regular)
                    }
                    .buttonStyle(.plain)

                    if largePreviews && horizontalSizeClass == .regular {
                        Button {
                            Task { await store.toggleRead(paper) }
                        } label: {
                            Image(systemName: paper.isRead ? "checkmark.circle.fill" : "checkmark.circle")
                                .foregroundStyle(.secondary)
                                .frame(width: 44, height: 44)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel(paper.isRead ? "Mark unread" : "Mark read")
                        .help(paper.isRead ? "Mark unread" : "Mark read")
                    }
                }
                .listRowBackground(Color.paperyBg)
                .listRowSeparatorTint(Color.paperyMeta.opacity(0.3))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    Button {
                        Task { await store.toggleRead(paper) }
                    } label: {
                        Label(paper.isRead ? "Unread" : "Read",
                              systemImage: paper.isRead ? "circle" : "checkmark.circle")
                    }
                    .tint(.gray)
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        Task { await store.delete(paper) }
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    Button {
                        Task { await store.toggleLike(paper) }
                    } label: {
                        Label("Like", systemImage: paper.isLiked ? "heart.slash" : "heart")
                    }
                    .tint(.paperyHeart)
                }
            }
            .onMove { source, destination in
                store.move(from: source, to: destination)
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.paperyBg.ignoresSafeArea())
        .refreshable {
            await store.load()
            Task.detached { await PaperyCache.refresh() }
        }
    }
}

struct PaperRow: View {
    let paper: Paper
    var roomyPreview = false

    var body: some View {
        HStack(alignment: .top, spacing: roomyPreview ? 12 : 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(paper.displayTitle)
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundStyle(paper.isRead ? Color.paperyMeta : Color.paperyInk)
                    .strikethrough(paper.isRead, color: .paperyMeta)
                    .lineLimit(2)

                HStack(spacing: 5) {
                    if let site = paper.site, !site.isEmpty {
                        Text(site)
                    }
                    Text("·")
                    Text(paper.addedDate, format: .relative(presentation: .named))
                    if paper.highlightCount > 0 {
                        Text("\(paper.highlightCount) hl")
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.paperyHlBg.opacity(0.28), in: Capsule())
                            .foregroundStyle(Color.paperyHlText)
                    }
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Color.paperyMeta)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            if paper.isLiked {
                Image(systemName: "heart.fill")
                    .font(.caption2)
                    .foregroundStyle(Color.paperyHeart)
            }

            PaperThumb(url: paper.url, width: roomyPreview ? 96 : 64, height: roomyPreview ? 72 : 48)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}


/// One-line status strip for the e-reader sync: what the BLE central is doing
/// and a manual kick. Lives at the bottom of the papery tab so it's visible
/// exactly where the content it syncs lives.
private struct LensStatusBar: View {
    @State private var lens = LensSyncService.shared

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "book.and.wrench")
                .font(.caption)
                .foregroundStyle(Color.paperyMeta)
            Text("lens: \(lens.statusText)")
                .font(.caption)
                .foregroundStyle(Color.paperyMeta)
                .lineLimit(1)
            Spacer()
            Button("sync") { lens.syncNow() }
                .font(.caption.weight(.medium))
                .buttonStyle(.bordered)
                .controlSize(.mini)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(Color.paperyBg)
    }
}
