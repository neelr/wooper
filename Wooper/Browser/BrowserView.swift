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
        BrowserSurface(session: session, allowsAnnotations: allowsAnnotations)
        .background(Color.paperyBg)
        .overlay(alignment: .leading) {
            if allowsAnnotations { annotationTools.padding(.leading, 12) }
        }
        .overlay(alignment: .bottomLeading) {
            Button {
                if session.controller?.saveNow() != false { dismiss() }
            } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 44)
            }
            .accessibilityLabel("Back to Papery")
            .modifier(FloatingBrowserGlass(shape: Circle()))
            .padding(12)
        }
        .overlay(alignment: .bottomTrailing) {
            if !allowsAnnotations {
                browserOptions.modifier(FloatingBrowserGlass(shape: Circle())).padding(12)
            }
        }
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
        .buttonStyle(.plain)
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

    private var annotationTools: some View {
        VStack(spacing: 4) {
            inkButton(.pen, symbol: "pencil.tip")
            inkButton(.highlighter, symbol: "highlighter")
            inkButton(.eraser, symbol: "eraser")
            Divider().frame(width: 26).padding(.vertical, 2)
            browserOptions
        }
        .padding(6)
        .modifier(FloatingBrowserGlass(shape: RoundedRectangle(cornerRadius: 26)))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Annotation tools")
        .accessibilityValue("Undo \(session.canUndo ? "available" : "unavailable"), redo \(session.canRedo ? "available" : "unavailable")")
        .accessibilityAction(named: "Undo annotation") { session.controller?.undoInk() }
        .accessibilityAction(named: "Redo annotation") { session.controller?.redoInk() }
    }

    private var browserOptions: some View {
        Menu {
            Button("Reload page", systemImage: "arrow.clockwise") { session.controller?.reload() }
            ShareLink(item: session.url)
            if allowsAnnotations {
                Toggle("Draw with finger", isOn: $session.drawsWithFinger)
                Toggle("Red ink", isOn: $session.redInk)
                Text("Draw to annotate. Hold to scroll; tiny initial marks disappear.")
                Text("Two-finger tap to undo. Three-finger tap to redo.")
            }
        } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }
        .accessibilityLabel("Browser options")
    }

    private func inkButton(_ ink: BrowserSession.Ink, symbol: String) -> some View {
        Button { session.ink = ink } label: {
            Image(systemName: symbol)
                .foregroundStyle(session.ink == ink ? Color.paperyInk : Color.paperyMeta)
                .font(.system(size: 20))
                .frame(width: 44, height: 44)
                .background(session.ink == ink ? Color.paperyHlBg.opacity(0.25) : .clear, in: Circle())
        }
        .accessibilityLabel(ink.rawValue.capitalized)
        .accessibilityAddTraits(session.ink == ink ? .isSelected : [])
    }
}

private struct FloatingBrowserGlass<S: Shape>: ViewModifier {
    let shape: S

    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: shape)
        } else {
            content.background(.regularMaterial, in: shape)
        }
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
