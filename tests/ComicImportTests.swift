import AppKit
import PDFKit
import ZIPFoundation

@main struct ComicImportTests {
    static func main() throws {
        func check(_ condition: Bool, _ message: String = "Assertion failed") { precondition(condition, message) }
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("comic-tests-" + UUID().uuidString)
        defer { try? fm.removeItem(at: root) }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        func png(_ name: String, color: NSColor) throws -> URL {
            let image = NSImage(size: NSSize(width: 40, height: 60))
            image.lockFocus(); color.setFill(); NSRect(x: 0, y: 0, width: 40, height: 60).fill(); image.unlockFocus()
            let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
            let url = root.appendingPathComponent(name)
            try bitmap.representation(using: .png, properties: [:])!.write(to: url)
            return url
        }
        let page2 = try png("page2.png", color: .white)
        let page10 = try png("page10.png", color: .black)
        let pdfURL = root.appendingPathComponent("Test Book.pdf")
        let pdf = PDFDocument()
        pdf.insert(PDFPage(image: NSImage(contentsOf: page2)!)!, at: 0)
        pdf.insert(PDFPage(image: NSImage(contentsOf: page10)!)!, at: 1)
        check(pdf.write(to: pdfURL))
        let archiveURL = root.appendingPathComponent("Test Archive.cbz")
        let archive = try Archive(url: archiveURL, accessMode: .create)
        try archive.addEntry(with: "page10.png", relativeTo: root)
        try archive.addEntry(with: "page2.png", relativeTo: root)
        let library = root.appendingPathComponent("library")
        let books = try ComicImporter.importBooks([pdfURL, archiveURL, page10, page2], into: library)
        check(books.count == 3)
        check(books[0].title == "test book" && books[0].pages.map(\.pdfPage) == [0, 1])
        check(books[1].pages.count == 2 && books[2].pages.count == 2)
        for book in books.dropFirst() {
            check(try Data(contentsOf: library.appendingPathComponent(book.pages[0].file)) == Data(contentsOf: page2))
            check(try Data(contentsOf: library.appendingPathComponent(book.pages[1].file)) == Data(contentsOf: page10))
        }
        let encoded = try JSONEncoder().encode(books)
        let decoded = try JSONDecoder().decode([ComicBook].self, from: encoded)
        check(decoded.flatMap(\.pages) == books.flatMap(\.pages))
        let bad = root.appendingPathComponent("broken.pdf")
        try Data("not a pdf".utf8).write(to: bad)
        let before = try fm.contentsOfDirectory(atPath: library.path).sorted()
        do {
            _ = try ComicImporter.importBooks([pdfURL, bad], into: library)
            fatalError("Invalid PDF should fail")
        } catch {}
        check(try fm.contentsOfDirectory(atPath: library.path).sorted() == before, "Failed import must roll back")
        print("PASS: PDF pages, CBZ extraction/order, image order, manifest round-trip, failed-import rollback")
    }
}
