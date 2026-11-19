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

/// Movement commits a contact to ink; a stationary hold commits it to scrolling.
/// Once chosen, the intent cannot change until the Pencil leaves the screen.
struct PencilScrollIntent {
    enum Mode: Equatable { case waiting, ink, scroll }
    private(set) var mode: Mode = .waiting
    private(set) var startTime: TimeInterval = 0
    private(set) var startPoint = CGPoint.zero
    static let holdDuration: TimeInterval = 0.3
    static let movementThreshold: CGFloat = 5

    mutating func begin(at point: CGPoint, time: TimeInterval) {
        startPoint = point
        startTime = time
        mode = .waiting
    }

    mutating func move(to point: CGPoint, time: TimeInterval) -> Mode {
        guard mode == .waiting else { return mode }
        // Movement before the hold wins, even when a coalesced event is delivered late.
        let distance = hypot(point.x - startPoint.x, point.y - startPoint.y)
        if distance > Self.movementThreshold { mode = .ink }
        else if time - startTime >= Self.holdDuration { mode = .scroll }
        return mode
    }

    mutating func hold() -> Mode {
        if mode == .waiting { mode = .scroll }
        return mode
    }
}
