import SwiftUI
import UniformTypeIdentifiers

struct ComicReaderView: View {
    var active: Bool
    @State private var library = ComicLibrary.shared
    @State private var importing = false
    @AppStorage("comics.outsideArtwork") private var outsideArtwork = true
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            Group {
                if library.pages.isEmpty {
                    ContentUnavailableView {
                        Label("calvin & hobbes", systemImage: "book.pages")
                    } description: {
                        Text("Add your comic books to start reading. PDF, CBZ, and images are supported.")
                    } actions: {
                        Button("add comics") { importing = true }
                    }
                } else {
                    ComicPageCurl(library: library)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 12)
                        .background(Color(red: 0.77, green: 0.72, blue: 0.62))
                }
            }
            .navigationTitle("calvin & hobbes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        ForEach(library.books) { book in
                            Button(book.title) { library.open(book) }
                        }
                        Toggle("outside artwork", isOn: $outsideArtwork)
                    } label: { Label("books", systemImage: "books.vertical") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { importing = true } label: { Label("add comics", systemImage: "plus") }
                        .disabled(library.importing)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                VStack(spacing: 4) {
                    if let error = library.error {
                        HStack {
                            Text(error)
                            Button("dismiss") { library.error = nil }
                        }
                    }
                    if !library.pages.isEmpty {
                        Text("\(library.currentBook?.title ?? "") · \(library.pageIndex + 1) / \(library.pages.count)")
                            .lineLimit(1)
                    }
                    if outsideArtwork, let status = library.outsideStatus { Text(status) }
                }
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .padding(8)
                .frame(maxWidth: .infinity)
                .background(Color(red: 0.97, green: 0.95, blue: 0.89))
            }
            .overlay {
                if library.importing {
                    ProgressView("adding comics…").padding(20).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .background {
                if #available(iOS 27.1, *) {
                    ComicOutsideBridge(active: active && scenePhase == .active && outsideArtwork)
                        .frame(width: 0, height: 0)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.pdf, .image, .zip, UTType(filenameExtension: "cbz") ?? .data], allowsMultipleSelection: true) { result in
                switch result {
                case .success(let urls): library.add(urls)
                case .failure(let error): library.error = error.localizedDescription
                }
            }
        }
        .tint(Color.paperyInk)
        .task { library.reload() }
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
    @State private var showingDetail = false
    var body: some View {
        ZStack {
            Color(red: 0.99, green: 0.98, blue: 0.94)
            if let page {
                ComicPageImage(page: page).padding(12)
                    .accessibilityLabel("comic page \(number + 1)")
            }
            HStack(spacing: 0) {
                if number.isMultiple(of: 2) { Spacer() }
                LinearGradient(colors: [.black.opacity(0.1), .clear], startPoint: number.isMultiple(of: 2) ? .trailing : .leading, endPoint: number.isMultiple(of: 2) ? .leading : .trailing)
                    .frame(width: 16).allowsHitTesting(false)
                if !number.isMultiple(of: 2) { Spacer() }
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { if page != nil { showingDetail = true } }
        .sheet(isPresented: $showingDetail) {
            if let page { ComicPageDetail(page: page) }
        }
    }
}

private struct ComicPageDetail: View {
    let page: ComicPage
    @Environment(\.dismiss) private var dismiss
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        NavigationStack {
            Group {
                if let image { ComicZoomImage(image: image) }
                else if failed { Text("page unavailable") }
                else { ProgressView() }
            }
            .navigationTitle("pinch to zoom")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("done") { dismiss() } }
            .task {
                image = await ComicRenderer.shared.image(for: page)
                failed = image == nil
            }
        }
    }
}

private struct ComicZoomImage: UIViewRepresentable {
    let image: UIImage
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> ComicZoomScrollView {
        let scroll = ComicZoomScrollView()
        scroll.delegate = context.coordinator
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 4
        scroll.bouncesZoom = true
        scroll.picture.image = image
        scroll.addSubview(scroll.picture)
        return scroll
    }
    func updateUIView(_ scroll: ComicZoomScrollView, context: Context) {}
    final class Coordinator: NSObject, UIScrollViewDelegate {
        func viewForZooming(in scrollView: UIScrollView) -> UIView? { (scrollView as? ComicZoomScrollView)?.picture }
        func scrollViewDidZoom(_ scrollView: UIScrollView) {
            guard let scroll = scrollView as? ComicZoomScrollView else { return }
            scroll.picture.center = CGPoint(x: max(scroll.contentSize.width, scroll.bounds.width) / 2,
                                             y: max(scroll.contentSize.height, scroll.bounds.height) / 2)
        }
    }
}

private final class ComicZoomScrollView: UIScrollView {
    let picture = UIImageView()
    private var viewport = CGSize.zero
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.size != viewport, bounds.width > 0, let image = picture.image else { return }
        viewport = bounds.size
        setZoomScale(1, animated: false)
        let scale = min(bounds.width / image.size.width, bounds.height / image.size.height)
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        picture.frame = CGRect(origin: CGPoint(x: (bounds.width-size.width)/2, y: (bounds.height-size.height)/2), size: size)
        contentSize = bounds.size
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
