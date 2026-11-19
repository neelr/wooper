import Foundation
import CoreGraphics

@main struct WebAnnotationTests {
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = WebAnnotationStore(directory: directory)
        let article = URL(string: "https://example.com/article?id=1")!
        let section = URL(string: "https://example.com/article?id=1#conclusion")!
        let other = URL(string: "https://example.com/article?id=2")!
        assert(WebAnnotationStore.accepts(article))
        assert(!WebAnnotationStore.accepts(URL(string: "file:///private/test")!))
        assert(!WebAnnotationStore.accepts(URL(string: "mailto:test@example.com")!))
        assert(store.file(for: article) == store.file(for: section))
        assert(store.file(for: article) != store.file(for: other))
        assert(store.file(for: URL(string: "https://example.com/#/one")!) != store.file(for: URL(string: "https://example.com/#/two")!))
        let missing = try store.load(article)
        assert(missing == nil)
        let record = WebAnnotationRecord(url: WebAnnotationStore.documentKey(article), pageWidth: 951, drawing: Data([1, 2, 3]))
        try store.save(record, for: article)
        let reopened = try WebAnnotationStore(directory: directory).load(section)
        assert(reopened == record, "Closing and reopening must preserve ink and original page width")
        let otherRecord = try store.load(other)
        assert(otherRecord == nil, "Another article cannot inherit the previous page's ink")
        var erased = record
        erased.drawing = Data()
        try store.save(erased, for: article)
        let emptyRecord = try store.load(article)
        assert(emptyRecord?.drawing == Data(), "Erasing the last stroke must persist")
        let corrupt = Data("not a saved document".utf8)
        try corrupt.write(to: store.file(for: article))
        do { _ = try store.load(article); assertionFailure("Corrupt data must surface an error") } catch {}
        let preserved = try Data(contentsOf: store.file(for: article))
        assert(preserved == corrupt)

        var intent = PencilScrollIntent()
        intent.begin(at: .zero, time: 10)
        assert(intent.move(to: CGPoint(x: 8, y: 0), time: 10.04) == .ink)
        assert(intent.hold() == .ink, "A pause partway through handwriting must never start scrolling")
        intent.begin(at: .zero, time: 20)
        assert(intent.move(to: CGPoint(x: 1, y: 1), time: 20.2) == .waiting)
        assert(intent.hold() == .scroll)
        assert(intent.move(to: CGPoint(x: 0, y: 300), time: 20.5) == .scroll, "A held drag must never turn into an ink stroke")
        intent.begin(at: .zero, time: 30)
        assert(intent.move(to: CGPoint(x: 0, y: 9), time: 30.01) == .ink, "Each new contact gets a fresh decision")
        print("PASS: URL isolation, atomic persistence, reopen, erase, corrupt-file preservation, and Pencil intent")
    }
}
