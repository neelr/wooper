import CryptoKit
import CoreGraphics
import Foundation

/// Each web document owns its ink and layout, independently of browser history.
struct WebAnnotationRecord: Codable, Equatable {
    var version = 1
    var url: String
    var pageWidth: Double
    var drawing: Data
    var updatedAt = Date()
}

struct WebAnnotationStore {
    let directory: URL

    init(directory: URL? = nil) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("WebAnnotations", isDirectory: true)
    }

    static func accepts(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    static func documentKey(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: true) else { return url.absoluteString }
        // Ordinary anchors are the same document. Hash-router paths are not.
        if let fragment = parts.fragment, !fragment.hasPrefix("/"), !fragment.hasPrefix("!") {
            parts.fragment = nil
        }
        return parts.string ?? url.absoluteString
    }

    func file(for url: URL) -> URL {
        let hash = SHA256.hash(data: Data(Self.documentKey(url).utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent(hash).appendingPathExtension("json")
    }

    func load(_ url: URL) throws -> WebAnnotationRecord? {
        let path = file(for: url)
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let record = try JSONDecoder().decode(WebAnnotationRecord.self, from: Data(contentsOf: path))
        guard record.version == 1, record.url == Self.documentKey(url),
              record.pageWidth.isFinite, (200...3000).contains(record.pageWidth) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return record
    }

    func save(_ record: WebAnnotationRecord, for url: URL) throws {
        guard record.url == Self.documentKey(url), record.version == 1,
              record.pageWidth.isFinite, (200...3000).contains(record.pageWidth) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(record).write(to: file(for: url), options: .atomic)
    }
}

/// A contact starts in the selected mode. A stationary hold switches it once;
/// the browser carries the new mode into later contacts.
struct PencilScrollIntent {
    enum Mode: Equatable { case ink, scroll }
    private(set) var mode: Mode = .scroll
    private(set) var initialMode: Mode = .scroll
    private(set) var startPoint = CGPoint.zero
    private(set) var maximumDistance: CGFloat = 0
    private(set) var didToggle = false
    static let holdDuration: TimeInterval = 0.3
    static let movementThreshold: CGFloat = 5
    static let provisionalRadius: CGFloat = 24
    var canToggle: Bool {
        !didToggle && maximumDistance <= (initialMode == .ink ? Self.provisionalRadius : Self.movementThreshold)
    }

    mutating func begin(at point: CGPoint, mode: Mode) {
        startPoint = point
        self.mode = mode
        initialMode = mode
        maximumDistance = 0
        didToggle = false
    }

    mutating func move(to point: CGPoint) {
        let distance = hypot(point.x - startPoint.x, point.y - startPoint.y)
        maximumDistance = max(maximumDistance, distance)
    }

    @discardableResult mutating func toggleOnHold() -> Bool {
        guard canToggle else { return false }
        mode = mode == .scroll ? .ink : .scroll
        didToggle = true
        return true
    }
}
