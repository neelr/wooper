import SwiftUI
import UniformTypeIdentifiers

struct ComicReaderView: View {
    var active: Bool
    var onBack: () -> Void = {}
    @State private var library = ComicLibrary.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.white.ignoresSafeArea()
            if library.pages.isEmpty {
                ContentUnavailableView("calvin & hobbes", systemImage: "book.closed", description: Text("Your comics will appear here."))
            } else {
                ComicPageCurl(library: library)
                    .padding(.bottom, 34)
            }
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 15, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back to Papery")
            .padding(.leading, 8)
        }
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .background {
            if #available(iOS 27.1, *) {
                ComicOutsideBridge(active: active && scenePhase == .active)
                    .frame(width: 0, height: 0)
            }
        }
        .task { if active { library.reload(); library.openRandomSpread() } }
        .onChange(of: active) { _, active in
            if active { library.reload(); library.openRandomSpread() }
        }
    }
}

struct ComicPageImage: View {
    let page: ComicPage
    var fill = false
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().aspectRatio(contentMode: fill ? .fill : .fit) }
            else if failed { Label("page unavailable", systemImage: "photo.badge.exclamationmark").font(.caption) }
            else { ProgressView() }
        }
        .task(id: page.id) {
            image = nil; failed = false
            let rendered = await ComicRenderer.shared.image(for: page)
            guard !Task.isCancelled else { return }
            image = rendered; failed = rendered == nil
        }
    }
}

private struct ComicLeaf: View {
    let page: ComicPage?
    let number: Int
    var body: some View {
        ZStack {
            Color.white
            if let page {
                ComicPageImage(page: page).padding(6)
                    .accessibilityLabel("comic page \(number + 1)")
            }
            HStack(spacing: 0) {
                if number.isMultiple(of: 2) { Spacer() }
                LinearGradient(colors: [.black.opacity(0.1), .clear], startPoint: number.isMultiple(of: 2) ? .trailing : .leading, endPoint: number.isMultiple(of: 2) ? .leading : .trailing)
                    .frame(width: 16).allowsHitTesting(false)
                if !number.isMultiple(of: 2) { Spacer() }
            }
        }
    }
}

private final class ComicLeafController: UIHostingController<ComicLeaf> {
    let index: Int
    init(index: Int, page: ComicPage?) {
        self.index = index
        super.init(rootView: ComicLeaf(page: page, number: index))
    }
    @MainActor required dynamic init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
}

/// UIKit supplies interactive paper curls, including the reverse of each leaf.
private struct ComicPageCurl: UIViewControllerRepresentable {
    let library: ComicLibrary
    func makeCoordinator() -> Coordinator { Coordinator(library: library) }
    func makeUIViewController(context: Context) -> UIPageViewController {
        let controller = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal,
                                              options: [.spineLocation: UIPageViewController.SpineLocation.mid.rawValue])
        controller.isDoubleSided = true
        controller.dataSource = context.coordinator
        controller.delegate = context.coordinator
        context.coordinator.update(controller)
        return controller
    }
    func updateUIViewController(_ controller: UIPageViewController, context: Context) { context.coordinator.update(controller) }

    @MainActor final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        let library: ComicLibrary
        var pages: [ComicPage] = []
        var turning = false
        init(library: ComicLibrary) { self.library = library }
        var count: Int { max(2, pages.count + pages.count % 2) }
        func leaf(_ index: Int) -> ComicLeafController {
            let wrapped = (index + count) % count
            return ComicLeafController(index: wrapped, page: pages.indices.contains(wrapped) ? pages[wrapped] : nil)
        }
        func update(_ controller: UIPageViewController) {
            guard !turning else { return }
            let changed = pages != library.pages
            pages = library.pages
            let left = library.pageIndex / 2 * 2
            if changed || (controller.viewControllers?.first as? ComicLeafController)?.index != left {
                controller.setViewControllers([leaf(left), leaf(left + 1)], direction: .forward, animated: false)
            }
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerBefore viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? ComicLeafController else { return nil }
            return leaf(page.index - 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, viewControllerAfter viewController: UIViewController) -> UIViewController? {
            guard let page = viewController as? ComicLeafController else { return nil }
            return leaf(page.index + 1)
        }
        func pageViewController(_ pageViewController: UIPageViewController, willTransitionTo pendingViewControllers: [UIViewController]) { turning = true }
        func pageViewController(_ controller: UIPageViewController, didFinishAnimating finished: Bool, previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            turning = false
            if completed, let leaf = controller.viewControllers?.first as? ComicLeafController {
                library.turn(to: leaf.index)
            }
            update(controller)
        }
    }
}

/// Like DS, the presented full-screen controller owns the orientation lock.
@available(iOS 27.1, *)
struct ComicModePresenter: UIViewControllerRepresentable {
    let active: Bool
    let onBack: () -> Void

    func makeUIViewController(context: Context) -> Presenter { Presenter() }
    func updateUIViewController(_ controller: Presenter, context: Context) {
        controller.active = active
        controller.onBack = onBack
        DispatchQueue.main.async { controller.reconcile() }
    }
    static func dismantleUIViewController(_ controller: Presenter, coordinator: ()) {
        controller.active = false
        controller.reconcile()
    }

    final class Presenter: UIViewController {
        var active = false
        var onBack: () -> Void = {}
        private var host: ComicPortraitController<ComicReaderView>?
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            reconcile()
        }
        func reconcile() {
            guard active else {
                if let host {
                    self.host = nil
                    host.dismiss(animated: false)
                }
                return
            }
            guard host == nil, view.window != nil, presentedViewController == nil else { return }
            let host = ComicPortraitController(rootView: ComicReaderView(active: true) { [weak self] in
                guard let self else { return }
                self.active = false
                self.reconcile()
                self.onBack()
            })
            host.modalPresentationStyle = .fullScreen
            self.host = host
            present(host, animated: false)
        }
    }
}

@available(iOS 27.1, *)
final class ComicPortraitController<Content: View>: UIHostingController<Content> {
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .portrait }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .portrait }
    override var prefersInterfaceOrientationLocked: Bool { true }
    override var childForInterfaceOrientationLock: UIViewController? { nil }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        setNeedsUpdateOfSupportedInterfaceOrientations()
        setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        view.window?.windowScene?.requestGeometryUpdate(.iOS(interfaceOrientations: .portrait))
    }
}
