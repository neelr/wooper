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


struct PaperStatusChange: Codable, Equatable {
    enum Kind: String, Codable {
        case read, unread, liked, unliked
        var label: String {
            switch self {
            case .read: return "Marked read"
            case .unread: return "Marked unread"
            case .liked: return "Liked"
            case .unliked: return "Unliked"
            }
        }
    }
    let kind: Kind
    let timestamp: Double
    var date: Date { Date(timeIntervalSince1970: timestamp / 1000) }

    func matches(_ paper: Paper) -> Bool {
        switch kind {
        case .read: return paper.isRead
        case .unread: return !paper.isRead
        case .liked: return paper.isLiked
        case .unliked: return !paper.isLiked
        }
    }
}

extension Paper {
    func latestStatusChange(local: PaperStatusChange?) -> PaperStatusChange? {
        var changes: [PaperStatusChange] = []
        if let readAt { changes.append(.init(kind: .read, timestamp: readAt)) }
        if let likedAt { changes.append(.init(kind: .liked, timestamp: likedAt)) }
        if let local, local.matches(self) { changes.append(local) }
        return changes.max { $0.timestamp < $1.timestamp }
    }
}
