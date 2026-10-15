import Foundation
import PlateKit

/// Network seam so the court clients are testable without a network and so apps choose the session (and its policy).
public protocol HTTPFetching: Sendable {
    func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int)
}

public struct URLSessionFetcher: HTTPFetching {
    private let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        let (data, response) = try await session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

public enum CourtClientError: Error, Equatable {
    case http(Int), decoding, notAllowed(String)
}

/// A docket from a court source, with the fields as the source words them. No party roles, no summary: a docket's
/// existence is not a finding (allegation ≠ fact).
public struct CourtDocket: Sendable, Hashable, Codable {
    public var source: String            // "courtlistener" | "pacer"
    public var caseName: String
    public var docketNumber: String
    public var court: String
    public var filedOn: Date?
    public var terminatedOn: Date?
    public var url: URL?

    public init(source: String, caseName: String, docketNumber: String, court: String,
                filedOn: Date? = nil, terminatedOn: Date? = nil, url: URL? = nil) {
        self.source = source; self.caseName = caseName; self.docketNumber = docketNumber; self.court = court
        self.filedOn = filedOn; self.terminatedOn = terminatedOn; self.url = url
    }

    /// Dockets become pending candidates like every other record. The status says only what the source's dates say.
    public func candidate(retrievedAt: Date) -> RecordCandidate {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = "yyyy-MM-dd"
        let status = terminatedOn.map { "terminated \(df.string(from: $0))" } ?? filedOn.map { "filed \(df.string(from: $0))" } ?? ""
        let excerpt = "\(caseName) — \(docketNumber) — \(court)"
        return RecordCandidate(kind: .lawsuit, reference: "\(docketNumber) (\(court))", status: status,
                               subjectName: nil, agencyName: nil, releasedBy: court, filedOn: filedOn, excerpt: excerpt,
                               citation: SourceCitation(sourceType: .courtDocket, url: url, retrievedAt: retrievedAt,
                                                        excerptHashSHA256: Hashing.sha256Hex(excerpt)))
    }
}

/// Free Law Project's CourtListener / RECAP archive (free; an API token is optional and raises limits).
/// Endpoint shape from the public v4 API docs — **UNVERIFIED against the live service in this repo's tests**; the
/// parser is tolerant of missing fields and the fetch path is exercised only by a fake in unit tests.
public struct CourtListenerClient: Sendable {
    public static let searchURL = URL(string: "https://www.courtlistener.com/api/rest/v4/search/")!
    private let fetcher: HTTPFetching
    private let token: String?

    public init(fetcher: HTTPFetching = URLSessionFetcher(), token: String? = nil) {
        self.fetcher = fetcher; self.token = token
    }

    public func request(query: String, page: Int = 1) -> URLRequest {
        var comps = URLComponents(url: Self.searchURL, resolvingAgainstBaseURL: false)!
        comps.queryItems = [.init(name: "q", value: query), .init(name: "type", value: "r"),
                            .init(name: "order_by", value: "dateFiled desc"), .init(name: "page", value: String(page))]
        var req = URLRequest(url: comps.url!)
        req.setValue("PlateWatch records workspace (open-source accountability tool)", forHTTPHeaderField: "User-Agent")
        if let token { req.setValue("Token \(token)", forHTTPHeaderField: "Authorization") }
        return req
    }

    public func search(query: String, page: Int = 1) async throws -> [CourtDocket] {
        let (data, status) = try await fetcher.fetch(request(query: query, page: page))
        guard status == 200 else { throw CourtClientError.http(status) }
        return try Self.parse(data)
    }

    public static func parse(_ data: Data) throws -> [CourtDocket] {
        struct Response: Decodable { var results: [Row] }
        struct Row: Decodable {
            var caseName: String?, docketNumber: String?, court: String?, court_id: String?
            var dateFiled: String?, dateTerminated: String?, docket_absolute_url: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw CourtClientError.decoding }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = "yyyy-MM-dd"
        return response.results.compactMap { r in
            guard let number = r.docketNumber, !number.isEmpty else { return nil }
            return CourtDocket(source: "courtlistener", caseName: r.caseName ?? "", docketNumber: number,
                               court: r.court ?? r.court_id ?? "",
                               filedOn: r.dateFiled.flatMap { df.date(from: String($0.prefix(10))) },
                               terminatedOn: r.dateTerminated.flatMap { df.date(from: String($0.prefix(10))) },
                               url: r.docket_absolute_url.flatMap { URL(string: "https://www.courtlistener.com" + $0) })
        }
    }
}
