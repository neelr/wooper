import Foundation
import PDFKit
import ImageIO
import ZIPFoundation

struct ComicPage: Codable, Identifiable, Hashable {
    let file: String
    var pdfPage: Int? = nil
    var id: String { "\(file):\(pdfPage ?? -1)" }
}

struct ComicBook: Codable, Identifiable {
    let id: String
    let title: String
    let pages: [ComicPage]
}

enum ComicImportError: LocalizedError {
    case invalid(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Imports only supported page files; archive paths never become output paths.
enum ComicImporter {
    static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "webp", "heic", "tif", "tiff", "gif"]
    static func importBooks(_ urls: [URL], into root: URL) throws -> [ComicBook] {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var imported: [ComicBook] = []
        var created: [URL] = []
        do {
            let images = urls.filter { imageExtensions.contains($0.pathExtension.lowercased()) }
            let groups = urls.filter { !imageExtensions.contains($0.pathExtension.lowercased()) }.map { [$0] }
                + (images.isEmpty ? [] : [images.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }])
            for group in groups {
                let id = UUID().uuidString
                let dir = root.appending(path: id)
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
                created.append(dir)
                let first = group[0]
                let ext = first.pathExtension.lowercased()
                var pages: [ComicPage] = []
                if ext == "pdf" {
                    let target = dir.appending(path: "book.pdf")
                    try fm.copyItem(at: first, to: target)
                    guard let document = PDFDocument(url: target), !document.isLocked, document.pageCount > 0 else {
                        throw ComicImportError.invalid("This PDF is empty, locked, or unreadable.")
                    }
                    pages = (0..<document.pageCount).map { ComicPage(file: "\(id)/book.pdf", pdfPage: $0) }
                } else if ext == "cbz" || ext == "zip" {
                    let archive = try Archive(url: first, accessMode: .read)
                    let entries = archive.filter {
                        $0.type == .file && !$0.path.hasPrefix("__MACOSX/") && imageExtensions.contains(URL(fileURLWithPath: $0.path).pathExtension.lowercased())
                    }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
                    guard !entries.isEmpty, entries.count <= 20000 else { throw ComicImportError.invalid("No readable comic pages in this archive, or too many pages.") }
                    var total: UInt64 = 0
                    for (i, entry) in entries.enumerated() {
                        total += UInt64(entry.uncompressedSize)
                        guard entry.uncompressedSize <= 100 * 1024 * 1024, total <= 4 * 1024 * 1024 * 1024 else {
                            throw ComicImportError.invalid("This archive is too large to import.")
                        }
                        let name = "\(i)." + URL(fileURLWithPath: entry.path).pathExtension.lowercased()
                        let target = dir.appending(path: name)
                        _ = try archive.extract(entry, to: target)
                        try validateImage(target)
                        pages.append(ComicPage(file: "\(id)/\(name)"))
                    }
                } else if imageExtensions.contains(ext) {
                    for (i, source) in group.enumerated() {
                        let name = "\(i)." + source.pathExtension.lowercased()
                        let target = dir.appending(path: name)
                        try fm.copyItem(at: source, to: target)
                        try validateImage(target)
                        pages.append(ComicPage(file: "\(id)/\(name)"))
                    }
                } else { throw ComicImportError.invalid("Choose PDF, CBZ, or image files.") }
                imported.append(ComicBook(id: id, title: first.deletingPathExtension().lastPathComponent.lowercased(), pages: pages))
            }
            return imported
        } catch {
            for dir in created { try? fm.removeItem(at: dir) }
            throw error
        }
    }

    private static func validateImage(_ url: URL) throws {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ComicImportError.invalid("A comic page could not be read.")
        }
    }
}

