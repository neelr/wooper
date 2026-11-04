import SwiftUI
import Combine
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
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var ds = DSModel()
    @State private var standby = StandbyTrigger()
    @State private var standbyData = StandbyData()
    @State private var standbyStatusBarHidden = false
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var standbyClock = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    private var supportsDS: Bool { Self.isDuo && sizeClass == .regular }
    private var standbyLayout: StandbyLayout? {
        StandbyLayout.resolve(isDuo: Self.isDuo, horizontalRegular: sizeClass == .regular,
                              verticalRegular: verticalSizeClass == .regular)
    }

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
        navigationTabs
            .allowsHitTesting(!standby.visible)
            .accessibilityHidden(standby.visible)
            .background {
                if #available(iOS 27.1, *) {
                    ComicModePresenter(active: selectedTab == .comics && supportsDS) {
                        selectedTab = .papery
                    }
                }
            }
        .background {
            if #available(iOS 27.1, *), Self.isDuo {
                StandbySensor(trigger: standby)
            }
        }
        .overlay {
            ZStack {
                if standby.visible {
                    StandbyView(stacked: standby.stacked, compactScreen: standbyLayout == .tent, trigger: standby, data: standbyData) {
                        standby.policy.dismiss()
                    }
                    .ignoresSafeArea()
                    .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: reduceMotion ? 0.2 : (standby.visible ? 0.8 : 0.65)), value: standby.visible)
        }
        .modifier(StandbyHingeObserver(trigger: standby, enabled: Self.isDuo))
        .statusBarHidden(standbyStatusBarHidden)
        .task(id: standby.visible) {
            if standby.visible {
                // Hide system chrome only after the opaque standby canvas covers
                // Papery. Its full-screen geometry is independent of safe areas.
                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 250 : 850)) }
                catch { return }
                standbyStatusBarHidden = true
            } else {
                standbyStatusBarHidden = false
            }
        }
        .onReceive(standbyClock) { date in
            guard scenePhase == .active else { return }
            let eligible = standbyLayout != nil && selectedTab == .papery &&
                !standby.keyboardVisible && standby.canPresent
            #if DEBUG
            standby.eligible = eligible
            #endif
            standby.policy.tick(eligible: eligible, now: date)
        }
        .onChange(of: selectedTab) { _, _ in standby.policy.leave() }
        .onChange(of: standbyLayout, initial: true) { _, layout in
            standby.updateLayout(layout)
            if layout == nil { standby.policy.leave() }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { standby.policy.leave() }
            if phase == .active { standby.policy.interact() }
        }
        .onChange(of: supportsDS) { _, supported in
            if !supported, selectedTab == .comics { selectedTab = .papery }
        }
    }

    private var navigationTabs: some View {
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
                Color.clear
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
