import Foundation
import SwiftData

@Model
final class Recording {
    var id: UUID
    var title: String
    var date: Date
    var duration: TimeInterval
    var fileName: String
    var cdnURL: String?
    var notionURL: String?

    var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return docs.appendingPathComponent(fileName)
    }

    init(title: String, date: Date = .now, duration: TimeInterval = 0, fileName: String) {
        self.id = UUID()
        self.title = title
        self.date = date
        self.duration = duration
        self.fileName = fileName
    }
}
