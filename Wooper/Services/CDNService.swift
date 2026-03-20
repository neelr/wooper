import Foundation

struct CDNUploadResponse: Codable {
    let success: Bool
    let url: String?
}

enum CDNService {
    private static let baseURL = "https://cdn.neelr.dev"
    private static let token = Secrets.cdnToken

    static func upload(fileURL: URL) async throws -> String {
        let url = URL(string: "\(baseURL)/api/upload")!
        var request = URLRequest(url: url)
        request.httpMethod = "POST"

        let boundary = UUID().uuidString
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        let fileData = try Data(contentsOf: fileURL)
        let fileName = fileURL.lastPathComponent

        var body = Data()

        // Token field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"token\"\r\n\r\n")
        body.append("\(token)\r\n")

        // File field
        body.append("--\(boundary)\r\n")
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(fileName)\"\r\n")
        body.append("Content-Type: audio/mp4\r\n\r\n")
        body.append(fileData)
        body.append("\r\n")

        body.append("--\(boundary)--\r\n")

        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let result = try JSONDecoder().decode(CDNUploadResponse.self, from: data)
        guard result.success, let path = result.url else {
            throw URLError(.cannotParseResponse)
        }

        return "\(baseURL)\(path)"
    }
}

private extension Data {
    mutating func append(_ string: String) {
        if let data = string.data(using: .utf8) {
            append(data)
        }
    }
}
