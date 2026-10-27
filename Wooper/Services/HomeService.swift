import Foundation

enum HomeServiceError: LocalizedError {
    case badURL
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .badURL: return "bad url"
        case .badResponse(let code): return "request failed (\(code))"
        }
    }
}

/// Stateless client for the `home` smart-home API over the tailnet.
/// Same enum-of-static-async-methods shape as ClaudeService / NotionService.
enum HomeService {
    static let base = "http://home.tail90f369.ts.net"
    private static let key = Secrets.homeAPIKey

    private static func request(_ path: String, method: String = "GET", body: [String: Any]? = nil) throws -> URLRequest {
        guard let url = URL(string: base + path) else { throw HomeServiceError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue(key, forHTTPHeaderField: "Authorization")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        return req
    }

    @discardableResult
    private static func send(_ req: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: req)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(code) else { throw HomeServiceError.badResponse(code) }
        return data
    }

    static func fetchState() async throws -> HomeState {
        let data = try await send(try request("/api/state"))
        return try JSONDecoder().decode(HomeState.self, from: data)
    }

    static func toggle(_ id: String) async throws {
        try await send(try request("/api/lights/\(id)/toggle", method: "POST", body: [:]))
    }

    static func setLight(_ id: String, brightness: Int? = nil, kelvin: Int? = nil, on: Bool? = nil) async throws {
        var body: [String: Any] = [:]
        if let brightness { body["brightness"] = brightness }
        if let kelvin { body["kelvin"] = kelvin }
        if let on { body["on"] = on }
        try await send(try request("/api/lights/\(id)", method: "POST", body: body))
    }

    static func allLights(on: Bool) async throws {
        try await send(try request("/api/lights/all", method: "POST", body: ["on": on]))
    }

    static func vacuum(_ action: String) async throws {
        try await send(try request("/api/vacuum/\(action)", method: "POST", body: [:]))
    }
}
