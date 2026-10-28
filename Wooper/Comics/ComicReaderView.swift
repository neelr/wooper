import SwiftUI
import UniformTypeIdentifiers

struct ComicReaderView: View {
    var active: Bool
    var onBack: () -> Void = {}
    @State private var library = ComicLibrary.shared

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Color.white.ignoresSafeArea()
            if library.pages.isEmpty {
                ContentUnavailableView("calvin & hobbes", systemImage: "book.closed", description: Text("Your comics will appear here."))
            } else {
                ComicPageCurl(library: library)
                    .ignoresSafeArea(.container, edges: .bottom)
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
        safeAreaRegions = []
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
        private var host: ComicLandscapeController<ComicReaderView>?
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
            let host = ComicLandscapeController(rootView: ComicReaderView(active: true) { [weak self] in
                guard let self else { return }
                self.active = false
                self.reconcile()
                self.onBack()
            })
            host.providesOutsideArtwork = true
            host.onFold = { [weak self] in
                guard let self else { return }
                self.active = false
                self.reconcile()
                self.onBack()
            }
            host.modalPresentationStyle = .fullScreen
            self.host = host
            present(host, animated: false)
        }
    }
}

@available(iOS 27.1, *)
final class ComicLandscapeController<Content: View>: UIHostingController<Content> {
    var providesOutsideArtwork = false
    var onFold: (() -> Void)?
    private var outsideController: ComicOutsideController?
    private var observers: [NSObjectProtocol] = []
    private var exiting = false
    private var orientationLocked = false

    override func viewDidLoad() {
        super.viewDidLoad()
        registerForTraitChanges([UITraitHorizontalSizeClass.self]) { (controller: ComicLandscapeController<Content>, _: UITraitCollection) in
            controller.checkFold()
        }
    }

    private func checkFold() {
        guard onFold != nil, !exiting, view.window != nil,
              traitCollection.horizontalSizeClass == .compact else { return }
        exiting = true
        outsideController?.setActive(false)
        DispatchQueue.main.async { [weak self] in self?.onFold?() }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        checkFold()
        updateOrientationLock()
    }

    private func updateOrientationLock() {
        guard let scene = view.window?.windowScene else { return }
        let ready = scene.effectiveGeometry.interfaceOrientation == .landscapeRight
        guard orientationLocked != ready else { return }
        orientationLocked = ready
        setNeedsUpdateOfPrefersInterfaceOrientationLocked()
    }

    override func viewWillTransition(to size: CGSize, with coordinator: UIViewControllerTransitionCoordinator) {
        super.viewWillTransition(to: size, with: coordinator)
        coordinator.animate(alongsideTransition: nil) { [weak self] _ in
            self?.updateOrientationLock()
        }
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        outsideController?.setActive(false)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask { .landscapeRight }
    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation { .landscapeRight }
    override var prefersInterfaceOrientationLocked: Bool { orientationLocked }
    override var childForInterfaceOrientationLock: UIViewController? { nil }
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        checkFold()
        guard !exiting else { return }
        if providesOutsideArtwork {
            if outsideController == nil {
                let outside = ComicOutsideController()
                outside.registrationOwner = self
                addChild(outside)
                outside.view.frame = .zero
                view.addSubview(outside.view)
                outside.didMove(toParent: self)
                outsideController = outside
            }
            outsideController?.setActive(true)
            if observers.isEmpty, let scene = view.window?.windowScene {
                observers.append(NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.outsideController?.setActive(true) }
                })
                observers.append(NotificationCenter.default.addObserver(forName: UIScene.willDeactivateNotification, object: scene, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.outsideController?.setActive(false) }
                })
            }
        }
        // Locking before requesting geometry pins the orientation we entered in.
        // Let UIKit rotate first, then lock only the confirmed landscape geometry.
        updateOrientationLock()
        setNeedsUpdateOfSupportedInterfaceOrientations()
        setNeedsUpdateOfPrefersInterfaceOrientationLocked()
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.exiting, let scene = self.view.window?.windowScene else { return }
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            self.updateOrientationLock()
        }
    }
}
