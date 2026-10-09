import Foundation
import PlateKit

/// Portable REST protocol client — the language every non-Apple client
/// (and the reference Vapor mirror) speaks. JSON: UTF-8, ISO-8601 dates,
/// snake_case off (casing preserved). Bearer token is the device's ed25519
/// public key hash; requests are signed by `DeviceIdentity` elsewhere and
/// attached via the `X-PlateWatch-Signature` header hook.
public struct RESTBackend: SyncBackend {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func submit(_ sighting: SightingSubmissionDTO,
                       idempotencyKey: String) async throws -> SubmissionReceipt {
        var request = try JSONRequest.post(baseURL.appending(path: "v1/sightings"))
        request.setValue(idempotencyKey, forHTTPHeaderField: "Idempotency-Key")
        let receipt: SubmissionReceipt = try await request.send(sighting, using: session)
        return receipt
    }

    public func pullSightings(since cursor: SyncCursor?) async throws -> SightingDelta {
        var request = try JSONRequest.get(baseURL.appending(path: "v1/sightings"))
        if let cursor { request.url?.append(queryItems: [URLQueryItem(name: "cursor", value: cursor.token)]) }
        let page: SightingPageDTO = try await request.sendEmpty(using: session)
        return SightingDelta(sightings: page.items,
                             newCursor: page.nextCursor.map(SyncCursor.init))
    }

    public func vehicles(matchingPlate plateText: String) async throws -> [PublicVehicleDTO] {
        var comps = URLComponents(url: baseURL.appending(path: "v1/vehicles"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "plate", value: Plate.normalize(plateText))]
        let request = try JSONRequest.get(comps.url!)
        return try await request.sendEmpty(using: session)
    }

    public func ensureWatchlistSubscription() async throws {
        // REST reference server has no push; client apps poll via deltas.
    }
}

/// Minimal JSON request wrapper with the shared date conventions.
struct JSONRequest {
    enum Method: String { case get = "GET", post = "POST" }

    var url: URL?
    let method: Method
    var headers: [String: String] = ["Accept": "application/json"]

    static func get(_ url: URL) throws -> JSONRequest { JSONRequest(url: url, method: .get) }
    static func post(_ url: URL) throws -> JSONRequest { JSONRequest(url: url, method: .post) }

    mutating func setValue(_ value: String, forHTTPHeaderField field: String) {
        headers[field] = value
    }

    func sendEmpty<Out: Decodable>(using session: URLSession) async throws -> Out {
        try await sendRequest(bodyData: nil, using: session)
    }

    func send<Out: Decodable, In: Encodable>(_ body: In, using session: URLSession) async throws -> Out {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(body)
        return try await sendRequest(bodyData: data, using: session)
    }

    private func sendRequest<Out: Decodable>(bodyData: Data?,
                                             using session: URLSession) async throws -> Out {
        guard let url else { throw SyncError.serverRejected(reason: "malformed URL") }
        var req = URLRequest(url: url)
        req.httpMethod = method.rawValue
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        if let bodyData {
            req.httpBody = bodyData
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else { throw SyncError.offline }
        switch http.statusCode {
        case 200...299: break
        case 401, 403: throw SyncError.notAuthenticated
        case 429: throw SyncError.quotaExceeded
        default: throw SyncError.serverRejected(reason: "HTTP \(http.statusCode)")
        }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(Out.self, from: data)
    }
}
