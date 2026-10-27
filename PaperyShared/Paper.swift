import Foundation

/// A saved paper from the Papery reading list (`/api/papers.json`).
/// Timestamps are epoch milliseconds; `readAt`/`likedAt` are nil when unset.
struct Paper: Identifiable, Codable, Hashable {
    let id: Int
    let url: String
    let title: String?
    let site: String?
    let favicon: String?
    let addedAt: Double
    let readAt: Double?
    let likedAt: Double?
    let hlCount: Int?

    enum CodingKeys: String, CodingKey {
        case id, url, title, site, favicon
        case addedAt = "added_at"
        case readAt = "read_at"
        case likedAt = "liked_at"
        case hlCount = "hl_count"
    }

    var isRead: Bool { readAt != nil }
    var isLiked: Bool { likedAt != nil }
    var highlightCount: Int { hlCount ?? 0 }

    var displayTitle: String {
        if let title, !title.trimmingCharacters(in: .whitespaces).isEmpty {
            return title
        }
        return url
    }

    var addedDate: Date {
        Date(timeIntervalSince1970: addedAt / 1000)
    }
}
