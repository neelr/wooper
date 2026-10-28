import Foundation

enum PaperyError: LocalizedError {
    case notConfigured
    case badResponse(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Papery isn't configured. Set your token in PaperyConfig.swift."
        case .badResponse(let code): return "Papery request failed (\(code))."
        }
    }
}

/// Bearer-authenticated client for the Papery reading-list API. Style mirrors
/// the app's other services (see NotionService): a stateless enum of static
/// async methods over URLSession.
enum PaperyService {
    private static var base: String {
        var s = PaperyConfig.endpoint.trimmingCharacters(in: .whitespaces)
        while s.hasSuffix("/") { s.removeLast() }
        return s
    }

    private static func makeRequest(
        _ path: String,
        method: String = "GET",
        body: [String: Any]? = nil
    ) throws -> URLRequest {
        guard !PaperyConfig.token.isEmpty,
              PaperyConfig.token != "REPLACE_WITH_PAPERY_TOKEN",
              let url = URL(string: base + path)
        else { throw PaperyError.notConfigured }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("Bearer \(PaperyConfig.token)", forHTTPHeaderField: "Authorization")
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
        guard (200..<300).contains(code) else { throw PaperyError.badResponse(code) }
        return data
    }

    // MARK: - Push

    /// Register this phone's APNs token so the server can wake us when an
    /// article is saved (which in turn syncs the e-reader within seconds).
    static func registerPushToken(_ token: String) async throws {
        let req = try makeRequest("/api/push/register", method: "POST", body: ["token": token])
        try await send(req)
    }

    // MARK: - Reading list

    static func curiusFeed(from: Int) async throws -> CuriusFeedPage {
        let offset = -TimeZone.current.secondsFromGMT() / 60
        var request = try makeRequest("/api/curius/feed?from=\(from)&tz=\(offset)")
        request.timeoutInterval = 15
        let data = try await send(request)
        struct Response: Decodable { let html: String; let next: Int? }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return CuriusFeedPage(items: try CuriusFeedParser.parse(response.html), next: response.next)
    }

    static func list(read: String, liked: Bool, query: String) async throws -> [Paper] {
        var comps = URLComponents(string: base + "/api/papers.json")!
        comps.queryItems = [
            URLQueryItem(name: "read", value: read),
            URLQueryItem(name: "liked", value: liked ? "1" : "0"),
            URLQueryItem(name: "q", value: query),
        ]
        guard !PaperyConfig.token.isEmpty,
              PaperyConfig.token != "REPLACE_WITH_PAPERY_TOKEN",
              let url = comps.url
        else { throw PaperyError.notConfigured }

        var req = URLRequest(url: url)
        req.setValue("Bearer \(PaperyConfig.token)", forHTTPHeaderField: "Authorization")
        let data = try await send(req)
        struct Response: Codable { let papers: [Paper] }
        return try JSONDecoder().decode(Response.self, from: data).papers
    }

    static func toggleRead(id: Int) async throws {
        try await send(try makeRequest("/api/toggle-read/\(id)", method: "POST"))
    }

    static func toggleLike(id: Int) async throws {
        try await send(try makeRequest("/api/toggle-like/\(id)", method: "POST"))
    }

    static func curiusLibrary() async throws -> Set<String> {
        let data = try await send(try makeRequest("/api/curius/library"))
        struct Response: Decodable { let configured: Bool; let urls: [String: Int] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.configured ? Set(response.urls.keys.map(curiusURLKey)) : []
    }

    static func curiusURLKey(_ raw: String) -> String {
        var components = URLComponents(string: raw)
        components?.fragment = nil
        let scheme = components?.scheme?.lowercased()
        let host = components?.host?.lowercased()
        components?.scheme = scheme
        components?.host = host
        var key = components?.string ?? String(raw.split(separator: "#", maxSplits: 1).first ?? "")
        if key.hasSuffix("/") { key.removeLast() }
        return key
    }

    static func crossPostToCurius(url: String, title: String) async throws {
        let data = try await send(try makeRequest("/api/curius/save", method: "POST",
                                                  body: ["url": url, "title": title]))
        struct Response: Decodable { let ok: Bool }
        guard try JSONDecoder().decode(Response.self, from: data).ok else {
            throw PaperyError.badResponse(502)
        }
    }

    static func delete(id: Int) async throws {
        try await send(try makeRequest("/api/paper/\(id)", method: "DELETE"))
    }

    /// Reorder: drop `id` between its new neighbours (either may be nil at an
    /// edge). Matches the web grip-drag / fractional-position scheme.
    static func move(id: Int, prev: Int?, next: Int?) async throws {
        let body: [String: Any] = ["prev": prev ?? NSNull(), "next": next ?? NSNull()]
        try await send(try makeRequest("/api/move/\(id)", method: "POST", body: body))
    }

    /// Authenticated request for a page-screenshot thumbnail (/api/thumb).
    /// AsyncImage can't send headers, so callers fetch this themselves.
    static func thumbRequest(for pageURL: String) throws -> URLRequest {
        guard !PaperyConfig.token.isEmpty,
              PaperyConfig.token != "REPLACE_WITH_PAPERY_TOKEN",
              var comps = URLComponents(string: base + "/api/thumb")
        else { throw PaperyError.notConfigured }
        comps.queryItems = [URLQueryItem(name: "url", value: pageURL)]
        guard let url = comps.url else { throw PaperyError.notConfigured }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(PaperyConfig.token)", forHTTPHeaderField: "Authorization")
        return req
    }

    /// Save a URL to the list (used by the share extension). Returns the new id.
    @discardableResult
    static func save(url: String, title: String?) async throws -> Int? {
        var body: [String: Any] = ["url": url]
        if let title, !title.isEmpty { body["title"] = title }
        let data = try await send(try makeRequest("/api/save", method: "POST", body: body))
        let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        return obj?["id"] as? Int
    }

    // MARK: - Lens e-reader relay (BLE sync)
    //
    // These endpoints are shaped for the e-reader's tiny parser, and the phone
    // relays their bodies over BLE verbatim — no re-encoding.

    /// The compact device index as NDJSON bytes (header line, then one JSON
    /// record per line). Pushed to the reader byte-for-byte.
    static func deviceIndexNDJSON() async throws -> Data {
        try await send(try makeRequest("/api/device/index?format=ndjson"))
    }

    /// Article text for up to 25 ids, framed as repeated
    /// `<id u32 LE><byteLength u32 LE><utf8 text>`. Relayed verbatim.
    static func bundleData(ids: [Int]) async throws -> Data {
        let list = ids.prefix(25).map(String.init).joined(separator: ",")
        return try await send(try makeRequest("/api/device/bundle?ids=\(list)"))
    }

    /// Explicit read-state set (idempotent), used when relaying the reader's
    /// offline toggles — a blind toggle could invert if the state also changed
    /// on the website in the meantime.
    static func setRead(id: Int, read: Bool) async throws {
        try await send(try makeRequest("/api/read/\(id)", method: "POST", body: ["read": read]))
    }
}
