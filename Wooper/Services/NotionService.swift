import Foundation

enum NotionService {
    private static let token = Secrets.notionToken
    private static let databaseID = Secrets.notionDatabaseID
    private static let maxBlocksPerRequest = 100

    @discardableResult
    static func createEntry(title: String, transcript: String, audioURL: String) async throws -> String {
        let allBlocks = buildPageBlocks(transcript: transcript, audioURL: audioURL)

        // First batch: create page with up to 100 blocks
        let firstBatch = Array(allBlocks.prefix(maxBlocksPerRequest))

        let url = URL(string: "https://api.notion.com/v1/pages")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = [
            "parent": ["database_id": databaseID],
            "properties": [
                "Name": [
                    "title": [
                        ["text": ["content": "voice: \(title)"]]
                    ]
                ],
                "tags": [
                    "multi_select": [
                        ["name": "voice memo"]
                    ]
                ]
            ],
            "children": firstBatch
        ]

        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pageId = json["id"] as? String,
              let notionURL = json["url"] as? String else {
            throw URLError(.badServerResponse)
        }

        // If there are remaining blocks, append them in batches
        if allBlocks.count > maxBlocksPerRequest {
            let remaining = Array(allBlocks.dropFirst(maxBlocksPerRequest))
            for batchStart in stride(from: 0, to: remaining.count, by: maxBlocksPerRequest) {
                let batchEnd = min(batchStart + maxBlocksPerRequest, remaining.count)
                let batch = Array(remaining[batchStart..<batchEnd])
                try await appendBlocks(to: pageId, blocks: batch)
            }
        }

        return notionURL
    }

    private static func appendBlocks(to pageId: String, blocks: [[String: Any]]) async throws {
        let url = URL(string: "https://api.notion.com/v1/blocks/\(pageId)/children")!
        var request = URLRequest(url: url)
        request.httpMethod = "PATCH"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body: [String: Any] = ["children": blocks]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (_, response) = try await URLSession.shared.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
    }

    private static func buildPageBlocks(transcript: String, audioURL: String) -> [[String: Any]] {
        var blocks: [[String: Any]] = []

        // Transcript as paragraph blocks (2000 char limit per rich_text element)
        let chunkSize = 1900
        var remaining = transcript
        while !remaining.isEmpty {
            let chunk = String(remaining.prefix(chunkSize))
            remaining = String(remaining.dropFirst(chunkSize))
            blocks.append([
                "object": "block",
                "type": "paragraph",
                "paragraph": [
                    "rich_text": [
                        ["type": "text", "text": ["content": chunk]]
                    ]
                ]
            ])
        }

        // Divider
        blocks.append([
            "object": "block",
            "type": "divider",
            "divider": [String: Any]()
        ])

        // Audio link as bookmark
        blocks.append([
            "object": "block",
            "type": "bookmark",
            "bookmark": [
                "url": audioURL
            ]
        ])

        return blocks
    }
}
