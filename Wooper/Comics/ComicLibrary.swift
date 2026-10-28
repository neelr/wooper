import SwiftUI
import PDFKit
import ImageIO

@MainActor @Observable
final class ComicLibrary {
    static let shared = ComicLibrary()
    nonisolated static let root = URL.documentsDirectory.appending(path: "Comics")
    var books: [ComicBook] = []
    var importing = false
    var error: String?
    var pageIndex = 0
    var outsideStatus: String?
    var pages: [ComicPage] { books.flatMap(\.pages) }
    var currentBook: ComicBook? {
        guard pages.indices.contains(pageIndex) else { return books.first }
        let page = pages[pageIndex]
        return books.first { $0.pages.contains(page) }
    }

    init() {
        reload()
    }

    func reload() {
        guard !importing else { return }
        let manifest = Self.root.appending(path: "library.json")
        books = (try? JSONDecoder().decode([ComicBook].self, from: Data(contentsOf: manifest))) ?? []
        if let last = UserDefaults.standard.string(forKey: "comics.lastPage"),
           let index = pages.firstIndex(where: { $0.id == last }) { pageIndex = index }
        else { pageIndex = 0 }
    }

    func turn(to index: Int) {
        guard pages.indices.contains(index) else { return }
        pageIndex = index
        UserDefaults.standard.set(pages[index].id, forKey: "comics.lastPage")
    }

    func openRandomSpread() {
        guard !pages.isEmpty else { return }
        let spreadCount = (pages.count + 1) / 2
        var spread = Int.random(in: 0..<spreadCount)
        if spreadCount > 1, spread == pageIndex / 2 {
            spread = (spread + Int.random(in: 1..<spreadCount)) % spreadCount
        }
        turn(to: spread * 2)
    }

    func open(_ book: ComicBook) {
        guard let first = book.pages.first, let index = pages.firstIndex(of: first) else { return }
        turn(to: index)
    }

    func add(_ urls: [URL]) {
        guard !importing else { return }
        importing = true; error = nil
        // Keep security-scoped access alive for the entire background import.
        let scoped = urls.filter { $0.startAccessingSecurityScopedResource() }
        Task {
            defer { scoped.forEach { $0.stopAccessingSecurityScopedResource() }; importing = false }
            do {
                let imported = try await Task.detached(priority: .userInitiated) {
                    try ComicImporter.importBooks(urls, into: ComicLibrary.root)
                }.value
                let updated = books + imported
                do {
                    try JSONEncoder().encode(updated).write(to: Self.root.appending(path: "library.json"), options: .atomic)
                } catch {
                    for book in imported { try? FileManager.default.removeItem(at: Self.root.appending(path: book.id)) }
                    throw error
                }
                books = updated
                if let first = imported.first { open(first) }
            } catch { self.error = error.localizedDescription }
        }
    }
}

/// Render a bounded number of full-resolution pages, never the entire library.
actor ComicRenderer {
    static let shared = ComicRenderer()
    private let cache = NSCache<NSString, UIImage>()
    private let documents = NSCache<NSString, PDFDocument>()
    init() {
        cache.totalCostLimit = 64 * 1024 * 1024
        documents.countLimit = 2
    }
    func image(for page: ComicPage) -> UIImage? {
        if let cached = cache.object(forKey: page.id as NSString) { return cached }
        let url = ComicLibrary.root.appending(path: page.file)
        let image: UIImage?
        if let index = page.pdfPage {
            let key = url.path as NSString
            let document = documents.object(forKey: key) ?? PDFDocument(url: url)
            if let document { documents.setObject(document, forKey: key) }
            image = document?.page(at: index)?.thumbnail(of: CGSize(width: 1600, height: 2000), for: .cropBox)
        } else if let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2000,
                    kCGImageSourceCreateThumbnailWithTransform: true
                  ] as CFDictionary) {
            image = UIImage(cgImage: cg)
        } else { image = nil }
        if let image { cache.setObject(image, forKey: page.id as NSString, cost: Int(image.size.width * image.size.height * 4)) }
        return image
    }
}
