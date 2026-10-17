import Foundation
import Security

/// Moderator credential + server address for the console. The token lives in the macOS Keychain only (never in
/// UserDefaults, never in the repo). The Moderation section exists in the UI only while a token is stored — that is
/// a UI gate, not a security boundary: the server (`MODERATOR_TOKEN`) is what actually authorises decisions.
enum ModeratorAccess {
    private static let service = "org.platewatch.hub.moderator"
    private static let account = "moderator-token"
    static let serverKey = "moderatorServerURL"
    /// Enrolment (the "Moderator sign-in…" command) is only offered when this default is set:
    /// `defaults write org.platewatch.PlateWatchHub moderatorEnrollment -bool true`.
    static var enrollmentOffered: Bool { UserDefaults.standard.bool(forKey: "moderatorEnrollment") }

    static var token: String? {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static var serverURL: URL? { UserDefaults.standard.string(forKey: serverKey).flatMap(URL.init(string:)) }
    static var isEnrolled: Bool { token != nil && serverURL != nil }

    @discardableResult
    static func enroll(token: String, server: URL) -> Bool {
        remove()
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                   kSecAttrAccount as String: account, kSecValueData as String: Data(token.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { return false }
        UserDefaults.standard.set(server.absoluteString, forKey: serverKey)
        return true
    }

    static func remove() {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        SecItemDelete(q as CFDictionary)
    }
}

/// Talks to the reference server's moderator JSON API (`/moderator/api/…`).
struct ModerationClient: Sendable {
    struct Item: Decodable, Identifiable, Sendable {
        let id: UUID
        let capturedAt: Date
        let geohash6: String
        let unitNumber: String?
        let fleetConfidence: Double
    }
    enum Decision: String, Sendable { case approve, reject }
    enum ClientError: Error, LocalizedError {
        case notEnrolled, http(Int)
        var errorDescription: String? {
            switch self {
            case .notEnrolled: return "Not enrolled as a moderator."
            case .http(let code): return code == 401 ? "Server rejected the moderator token." : "Server returned HTTP \(code)."
            }
        }
    }

    let baseURL: URL
    let token: String
    var session: URLSession = .shared

    init?(access: Void = ()) {
        guard let url = ModeratorAccess.serverURL, let token = ModeratorAccess.token else { return nil }
        self.baseURL = url; self.token = token
    }

    init(baseURL: URL, token: String, session: URLSession) {
        self.baseURL = baseURL; self.token = token; self.session = session
    }

    private func request(_ path: String, method: String, body: Data? = nil) -> URLRequest {
        var r = URLRequest(url: baseURL.appending(path: path))
        r.httpMethod = method
        r.timeoutInterval = 15
        r.httpBody = body
        r.setValue("Basic " + Data("moderator:\(token)".utf8).base64EncodedString(), forHTTPHeaderField: "Authorization")
        r.setValue("1", forHTTPHeaderField: "X-PlateWatch-Moderator")
        if body != nil { r.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return r
    }

    func queue() async throws -> [Item] {
        let (data, response) = try await session.data(for: request("moderator/api/queue", method: "GET"))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { throw ClientError.http(code) }
        return try Self.decoder().decode([Item].self, from: data)
    }

    func health() async throws {
        var request = URLRequest(url: baseURL.appending(path: "health"))
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let (_, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ClientError.http((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
    }

    struct Takedown: Decodable, Identifiable, Sendable {
        let id: UUID
        let createdAt: Date?
        let sightingID: UUID?
        let reason: String
        let contact: String?
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let s = try d.singleValueContainer().decode(String.self)
            let f = ISO8601DateFormatter()
            f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = f.date(from: s) { return date }
            f.formatOptions = [.withInternetDateTime]
            if let date = f.date(from: s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "bad date \(s)"))
        }
        return decoder
    }

    func takedowns() async throws -> [Takedown] {
        let (data, response) = try await session.data(for: request("moderator/api/takedowns", method: "GET"))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { throw ClientError.http(code) }
        return try Self.decoder().decode([Takedown].self, from: data)
    }

    struct AuditEntry: Decodable, Identifiable, Sendable {
        let createdAt: Date?
        let action: String
        let target: String?
        let detail: String?
        // The API currently has no row ID. Give each decoded row its own identity so identical actions are not collapsed.
        let id = UUID()
        private enum CodingKeys: String, CodingKey { case createdAt, action, target, detail }
    }

    func audit() async throws -> [AuditEntry] {
        let (data, response) = try await session.data(for: request("moderator/api/audit", method: "GET"))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 200 { throw ClientError.http(code) }
        return try Self.decoder().decode([AuditEntry].self, from: data)
    }

    /// `hide` removes the sighting from every public surface for good; `dismiss` closes the request.
    func resolve(_ id: UUID, hide: Bool) async throws {
        let body = try JSONEncoder().encode(["action": hide ? "hide" : "dismiss"])
        let (_, response) = try await session.data(for: request("moderator/api/takedowns/\(id.uuidString)/resolve", method: "POST", body: body))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 204 { throw ClientError.http(code) }
    }

    func decide(_ id: UUID, _ decision: Decision) async throws {
        let body = try JSONEncoder().encode(["decision": decision.rawValue])
        let (_, response) = try await session.data(for: request("moderator/api/sightings/\(id.uuidString)/decision",
                                                                  method: "POST", body: body))
        if let code = (response as? HTTPURLResponse)?.statusCode, code != 204 { throw ClientError.http(code) }
    }
}
