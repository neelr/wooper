import SwiftUI

enum PaperyFilter: String, CaseIterable, Identifiable {
    case unread, all, liked, recent
    var id: String { rawValue }
    var label: String {
        switch self {
        case .unread: return "Unread"
        case .all: return "All"
        case .liked: return "Liked"
        case .recent: return "Recent"
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
    private var loadGeneration = 0
    private var statusChanges: [String: PaperStatusChange] = {
        guard let data = UserDefaults.standard.data(forKey: "papery.statusChanges") else { return [:] }
        return (try? JSONDecoder().decode([String: PaperStatusChange].self, from: data)) ?? [:]
    }()

    func statusChange(for paper: Paper) -> PaperStatusChange? {
        paper.latestStatusChange(local: statusChanges[String(paper.id)])
    }

    private func remember(_ paper: Paper, kind: PaperStatusChange.Kind) {
        statusChanges[String(paper.id)] = .init(kind: kind, timestamp: Date().timeIntervalSince1970 * 1000)
        if let data = try? JSONEncoder().encode(statusChanges) {
            UserDefaults.standard.set(data, forKey: "papery.statusChanges")
        }
    }

    @MainActor
    func load() async {
        loadGeneration += 1
        let generation = loadGeneration
        let requestedFilter = filter
        isLoading = true
        errorMessage = nil
        do {
            let fetched = try await PaperyService.list(
                read: filter.readParam,
                liked: filter.likedOnly,
                query: query
            )
            guard generation == loadGeneration else { return }
            if requestedFilter == .recent {
                papers = fetched.filter { statusChange(for: $0) != nil }.sorted {
                    let a = statusChange(for: $0)!.timestamp, b = statusChange(for: $1)!.timestamp
                    return a == b ? $0.id > $1.id : a > b
                }
            } else { papers = fetched }
        } catch {
            guard generation == loadGeneration else { return }
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
        do {
            try await PaperyService.toggleRead(id: paper.id)
            remember(paper, kind: paper.isRead ? .unread : .read)
            await load()
            nudgeReader()
        } catch { errorMessage = error.localizedDescription }
    }

    @MainActor
    func toggleLike(_ paper: Paper) async {
        do {
            try await PaperyService.toggleLike(id: paper.id)
            remember(paper, kind: paper.isLiked ? .unliked : .liked)
            await load()
            nudgeReader()
        } catch { errorMessage = error.localizedDescription }
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
        guard filter != .recent else { return }
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
                        store.filter == .recent ? "No recent status changes" : (store.filter == .liked ? "No liked papers" : "Nothing here"),
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
                    if store.filter != .recent { EditButton() }
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
                        PaperRow(paper: paper, roomyPreview: largePreviews && horizontalSizeClass == .regular,
                                 statusChange: store.filter == .recent ? store.statusChange(for: paper) : nil)
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
                .modifier(ShortReadSwipe(enabled: largePreviews && horizontalSizeClass == .regular, isRead: paper.isRead) {
                    Task { await store.toggleRead(paper) }
                })
                .moveDisabled(store.filter == .recent)
                .listRowBackground(Color.paperyBg)
                .listRowSeparatorTint(Color.paperyMeta.opacity(0.3))
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if !(largePreviews && horizontalSizeClass == .regular) {
                    Button {
                        Task { await store.toggleRead(paper) }
                    } label: {
                        Label(paper.isRead ? "Unread" : "Read",
                              systemImage: paper.isRead ? "circle" : "checkmark.circle")
                    }
                    .tint(.gray)
                    }
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
    var statusChange: PaperStatusChange? = nil

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
                    if let statusChange {
                        Text(statusChange.kind.label)
                        Text("·")
                        Text(statusChange.date, format: .relative(presentation: .named))
                    } else {
                        Text(paper.addedDate, format: .relative(presentation: .named))
                    }
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

            PaperThumb(url: paper.url, width: roomyPreview ? 112 : 64, height: roomyPreview ? 84 : 48)
        }
        .padding(.vertical, roomyPreview ? 8 : 4)
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


/// Expanded rows use a fixed travel distance rather than a fraction of their width.
private struct ShortReadSwipe: ViewModifier {
    let enabled: Bool
    let isRead: Bool
    let action: () -> Void
    @State private var distance: CGFloat = 0
    @State private var armed = false
    private let threshold: CGFloat = 112

    func body(content: Content) -> some View {
        if #available(iOS 18.0, *), enabled {
            content
                .offset(x: min(distance, 144))
                .background(alignment: .leading) {
                    if distance > 0 {
                        Image(systemName: isRead ? "circle" : "checkmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(armed ? Color.paperyInk : Color.paperyMeta)
                            .frame(width: 112)
                            .offset(x: -16 * (1 - min(distance / threshold, 1)))
                            .opacity(min(distance / 44, 1))
                            .frame(width: min(distance, 136), alignment: .leading)
                            .clipped()
                    }
                }
                .contentShape(Rectangle())
                .gesture(ReadPan { value, ended, cancelled in
                    distance = max(0, value)
                    let ready = distance >= threshold
                    if ready && !armed { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
                    armed = ready
                    if ended || cancelled {
                        let commit = ready && !cancelled
                        withAnimation(.easeOut(duration: 0.15)) { distance = 0; armed = false }
                        if commit { action() }
                    }
                })
        } else {
            content
        }
    }
}

@available(iOS 18.0, *)
private struct ReadPan: UIGestureRecognizerRepresentable {
    let changed: (CGFloat, Bool, Bool) -> Void

    func makeCoordinator(converter: CoordinateSpaceConverter) -> Coordinator { Coordinator() }
    func makeUIGestureRecognizer(context: Context) -> UIPanGestureRecognizer {
        let pan = UIPanGestureRecognizer()
        pan.maximumNumberOfTouches = 1
        pan.delegate = context.coordinator
        return pan
    }
    func handleUIGestureRecognizerAction(_ recognizer: UIPanGestureRecognizer, context: Context) {
        changed(recognizer.translation(in: recognizer.view).x,
                recognizer.state == .ended,
                recognizer.state == .cancelled || recognizer.state == .failed)
    }
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let pan = gestureRecognizer as? UIPanGestureRecognizer else { return false }
            let velocity = pan.velocity(in: pan.view)
            // Leave vertical scrolling and left-swipe Like/Delete to the List.
            return velocity.x > 0 && velocity.x > abs(velocity.y) * 1.5
        }
    }
}
