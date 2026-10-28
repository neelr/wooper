import SwiftUI
import SwiftData
import Darwin

/// Root container. Papery (reading list) is home; Record (Wooper) is the second
/// tab. This view is always mounted, so it — not a specific screen — owns the
/// recording intent listeners. That keeps Shortcuts / Siri / the Live Activity
/// stop button working no matter which tab is showing.
struct AppShell: View {
    @Environment(\.modelContext) private var modelContext
    private var recorder = AudioRecorderService.shared

    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var ds = DSModel()
    private var supportsDS: Bool { Self.isDuo && sizeClass == .regular }

    enum Tab { case papery, record, home, ds, comics }
    @State private var selectedTab: Tab = .papery

    // Hardware identifier observed on the user's Duo ("flippy").
    // Use hardware rather than its editable device name.
    private static let isDuo: Bool = {
        var systemInfo = utsname()
        guard uname(&systemInfo) == 0 else { return false }
        let model = withUnsafeBytes(of: &systemInfo.machine) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
        return model == "iPhone19,4"
    }()

    var body: some View {
        TabView(selection: $selectedTab) {
            PaperyListView(largePreviews: Self.isDuo)
                .tabItem { Label("Papery", systemImage: "books.vertical.fill") }
                .tag(Tab.papery)

            if !Self.isDuo {
                RecordingListView()
                    .tabItem { Label("Record", systemImage: "waveform") }
                    .tag(Tab.record)
            }

            if #available(iOS 27.1, *), supportsDS {
                DSView(model: ds)
                    .toolbar(.visible, for: .tabBar)
                    .background {
                        DSModePresenter(model: ds, active: selectedTab == .ds && supportsDS && ds.game != nil)
                    }
                    .tabItem { Label("DS", systemImage: "gamecontroller.fill") }
                    .tag(Tab.ds)
            }

            if !Self.isDuo {
                HomeControlView()
                    .tabItem { Label("Home", systemImage: "lightbulb.fill") }
                    .tag(Tab.home)
            }
            if #available(iOS 27.1, *), supportsDS {
                ComicReaderView(active: selectedTab == .comics)
                    .tabItem { Label("calvin & hobbes", systemImage: "book.pages") }
                    .tag(Tab.comics)
            }
        }
        .modifier(AdaptiveNavigationStyle())
        .tint(Color.paperyInk)
        .onChange(of: supportsDS) { _, supported in
            if !supported { ds.pause(); if selectedTab == .ds || selectedTab == .comics { selectedTab = .papery } }
        }
        .onChange(of: selectedTab) { _, tab in if tab != .ds { ds.pause() } }
        .onReceive(NotificationCenter.default.publisher(for: .startRecordingIntent)) { _ in
            if !Self.isDuo { selectedTab = .record }
            if !recorder.isRecording {
                recorder.startRecording()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopRecordingFromWidget)) { _ in
            if recorder.isRecording {
                RecordingProcessor.saveStoppedRecording(
                    recorder: recorder,
                    modelContext: modelContext
                )
            }
        }
    }

}

/// Keep navigation system-owned so supported SDKs can adapt bars to Duo poses.
private struct AdaptiveNavigationStyle: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 18.0, *) {
            content.tabViewStyle(.sidebarAdaptable)
        } else {
            content
        }
    }
}
