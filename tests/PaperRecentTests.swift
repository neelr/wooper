import Foundation

@main
struct PaperRecentTests {
    static func main() throws {
        func paper(read: Double?, liked: Double?) -> Paper {
            Paper(id: 1, url: "https://example.com", title: "Example", site: nil,
                  favicon: nil, addedAt: 100, readAt: read, likedAt: liked, hlCount: nil)
        }
        assert(paper(read: nil, liked: nil).latestStatusChange(local: nil) == nil)
        assert(paper(read: 200, liked: 300).latestStatusChange(local: nil)?.kind == .liked)
        let unread = PaperStatusChange(kind: .unread, timestamp: 400)
        assert(paper(read: nil, liked: 300).latestStatusChange(local: unread) == unread)
        // A newer server read must supersede a stale local mark-unread record.
        let remoteRead = paper(read: 500, liked: nil).latestStatusChange(local: unread)
        assert(remoteRead?.kind == .read && remoteRead?.timestamp == 500)
        let unliked = PaperStatusChange(kind: .unliked, timestamp: 600)
        assert(paper(read: 500, liked: nil).latestStatusChange(local: unliked) == unliked)
        let encoded = try JSONEncoder().encode(["1": unread])
        let decoded = try JSONDecoder().decode([String: PaperStatusChange].self, from: encoded)
        assert(decoded["1"] == unread)
        print("PASS recent status selection, cleared statuses, stale records, persistence")
    }
}
