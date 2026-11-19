import PencilKit
import SwiftUI

struct BrowserDestination: Identifiable {
    let id = UUID()
    let url: URL
}

@MainActor @Observable
final class BrowserSession {
    enum Ink: String, CaseIterable { case pen, highlighter, eraser }
    let initialURL: URL
    var url: URL
    var title = ""
    var loading = true
    var canGoBack = false
    var canGoForward = false
    var canUndo = false
    var canRedo = false
    var message: String?
    var saveStatus = ""
    var ink: Ink = .pen
    var redInk = false
    var drawsWithFinger = false
    @ObservationIgnored weak var controller: WebBrowserController?

    init(url: URL) { initialURL = url; self.url = url }
}

struct BrowserView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var session: BrowserSession
    private var allowsAnnotations: Bool { horizontalSizeClass == .regular && verticalSizeClass == .regular }

    init(url: URL) { _session = State(initialValue: BrowserSession(url: url)) }

    var body: some View {
        NavigationStack {
            BrowserSurface(session: session, allowsAnnotations: allowsAnnotations)
                .background(Color.paperyBg)
                .overlay(alignment: .top) {
                    if session.loading { ProgressView().padding(10).background(.regularMaterial, in: Capsule()).padding(8) }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if let message = session.message {
                        HStack {
                            Text(message).font(.system(.caption, design: .monospaced))
                            Spacer(minLength: 8)
                            Button("retry") { session.controller?.retry() }
                        }
                        .padding(12).background(Color.paperyBg)
                    }
                }
                .toolbarTitleDisplayMode(.inline)
                .toolbarBackground(Color.paperyBg, for: .navigationBar, .bottomBar)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button {
                            if session.controller?.saveNow() != false { dismiss() }
                        } label: { Image(systemName: "chevron.left") }
                        .accessibilityLabel("Back to Papery")
                    }
                    ToolbarItem(placement: .principal) {
                        VStack(spacing: 2) {
                            Text(session.url.host ?? "browser")
                                .font(.system(.subheadline, design: .monospaced)).lineLimit(1)
                            if allowsAnnotations && !session.saveStatus.isEmpty {
                                Text(session.saveStatus).font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Button("Reload page", systemImage: "arrow.clockwise") { session.controller?.reload() }
                            ShareLink(item: session.url)
                            if allowsAnnotations {
                                Toggle("Draw with finger", isOn: $session.drawsWithFinger)
                                Toggle("Red ink", isOn: $session.redInk)
                                Text("Quick Pencil strokes draw. Hold the tip still briefly, then drag to scroll.")
                            }
                        } label: { Image(systemName: "ellipsis.circle") }
                        .accessibilityLabel("Browser options")
                    }
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button { session.controller?.goBack() } label: { Image(systemName: "chevron.backward") }
                            .disabled(!session.canGoBack).accessibilityLabel("Previous page")
                        Button { session.controller?.goForward() } label: { Image(systemName: "chevron.forward") }
                            .disabled(!session.canGoForward).accessibilityLabel("Next page")
                        Spacer()
                        if allowsAnnotations {
                            inkButton(.pen, symbol: "pencil.tip")
                            inkButton(.highlighter, symbol: "highlighter")
                            inkButton(.eraser, symbol: "eraser")
                            Spacer()
                            Button { session.controller?.undoInk() } label: { Image(systemName: "arrow.uturn.backward") }
                                .disabled(!session.canUndo).accessibilityLabel("Undo annotation")
                            Button { session.controller?.redoInk() } label: { Image(systemName: "arrow.uturn.forward") }
                                .disabled(!session.canRedo).accessibilityLabel("Redo annotation")
                        }
                    }
                }
        }
        .tint(Color.paperyInk)
        .preferredColorScheme(.light)
        .onChange(of: session.ink) { _, _ in session.controller?.updateTool() }
        .onChange(of: session.redInk) { _, _ in session.controller?.updateTool() }
        .onChange(of: session.drawsWithFinger) { _, _ in session.controller?.updateTool() }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { session.controller?.saveNow() }
        }
        .onDisappear { session.controller?.saveNow() }
    }

    private func inkButton(_ ink: BrowserSession.Ink, symbol: String) -> some View {
        Button { session.ink = ink } label: {
            Image(systemName: symbol)
                .foregroundStyle(session.ink == ink ? Color.paperyInk : Color.paperyMeta)
                .padding(6)
                .background(session.ink == ink ? Color.paperyHlBg.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 8))
        }
        .accessibilityLabel(ink.rawValue.capitalized)
        .accessibilityAddTraits(session.ink == ink ? .isSelected : [])
    }
}

private struct BrowserSurface: UIViewControllerRepresentable {
    var session: BrowserSession
    var allowsAnnotations: Bool
    func makeUIViewController(context: Context) -> WebBrowserController {
        WebBrowserController(session: session, allowsAnnotations: allowsAnnotations)
    }
    func updateUIViewController(_ controller: WebBrowserController, context: Context) {
        controller.setAnnotationsAvailable(allowsAnnotations)
        controller.updateTool()
    }
    static func dismantleUIViewController(_ controller: WebBrowserController, coordinator: ()) { controller.saveNow() }
}
