import Foundation
import PlateKit

/// An operator's explicit, cited publication of machine-readable endpoints can supply a narrowly scoped permission
/// when its robots endpoint is broken. This is an intentional REP exception, not a claim that HTTP 5xx means allow.
/// A valid robots file, 401/403/429, TLS/network failures and unconfirmed feed terms still stop requests as usual.
public struct PublicAPIPermission: Sendable {
    public let host: String
    public let pathPrefixes: [String]
    public let citation: SourceCitation

    public init(host: String, pathPrefixes: [String], citation: SourceCitation) {
        self.host = host.lowercased()
        self.pathPrefixes = pathPrefixes
        self.citation = citation
    }

    public func allows(_ url: URL, robotsHTTPStatus: Int) -> Bool {
        guard (500...599).contains(robotsHTTPStatus), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host, url.port == nil || url.port == 443,
              citation.url?.scheme == "https", !pathPrefixes.isEmpty else { return false }
        guard !url.path.split(separator: "/").contains(".."), !url.path.contains("\\") else { return false }
        return pathPrefixes.contains { url.path.hasPrefix($0) }
    }

    /// Caltrans explicitly provides these CWWP2 files for application integration. Verified 2026-10-14:
    /// catalogues return 200; /robots.txt is an nginx 500. Scope only published CCTV image branches, not the whole site.
    public static let caltransCCTV = PublicAPIPermission(
        host: "cwwp2.dot.ca.gov",
        pathPrefixes: (1...12).map { "/data/d\($0)/cctv/image/" },
        citation: .init(sourceType: .officialPost,
                        url: URL(string: "https://cwwp2.dot.ca.gov/documentation/cctv/cctv.htm")!,
                        retrievedAt: Date(timeIntervalSince1970: 1_791_936_000)))
}
