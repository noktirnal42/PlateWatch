import Foundation
import PlateKit

/// An operator's explicit, cited publication of machine-readable endpoints can supply a narrowly scoped permission
/// when its robots endpoint is broken. This is an intentional REP exception, not a claim that HTTP 5xx means allow.
/// A valid robots file, 401/403/429, TLS/network failures and unconfirmed feed terms still stop requests as usual.
public struct PublicAPIPermission: Sendable {
    public let host: String
    public let pathPrefixes: [String]
    public let citation: SourceCitation
    private let permitsWowzaPlaceholder: Bool

    public init(host: String, pathPrefixes: [String], citation: SourceCitation, permitsWowzaPlaceholder: Bool = false) {
        self.host = host.lowercased()
        self.pathPrefixes = pathPrefixes
        self.citation = citation
        self.permitsWowzaPlaceholder = permitsWowzaPlaceholder
    }

    public func allows(_ url: URL, robotsHTTPStatus: Int) -> Bool {
        guard (500...599).contains(robotsHTTPStatus), url.scheme?.lowercased() == "https",
              url.host?.lowercased() == host, url.port == nil || url.port == 443,
              citation.url?.scheme == "https", !pathPrefixes.isEmpty else { return false }
        guard !url.path.split(separator: "/").contains(".."), !url.path.contains("\\") else { return false }
        return pathPrefixes.contains { url.path.hasPrefix($0) }
    }

    /// NV511 publishes these exact operator hosts and .stream HLS routes in its
    /// documented camera API. Their missing robots route sometimes responds
    /// with Wowza's generic HTTP 200 welcome page, rather than a robots policy.
    /// This exception never applies to a real policy, auth refusal or TLS error.
    public func allowsWowzaPlaceholder(_ url: URL) -> Bool {
        permitsWowzaPlaceholder && citation.url?.scheme == "https" && url.scheme?.lowercased() == "https"
            && url.host?.lowercased() == host && (url.port == nil || url.port == 443)
            && !url.path.split(separator: "/").contains("..") && !url.path.contains("\\")
            && url.path.contains(".stream/") && ["m3u8", "ts", "m4s", "mp4", "aac", "key"].contains(url.pathExtension.lowercased())
            && pathPrefixes.contains { url.path.hasPrefix($0) }
    }

    public static let nevada511Video: [PublicAPIPermission] =
        ["d2wse2", "d2wse1", "d3wse1", "d1wse5", "d1wse2", "d1wse3", "d1wse4", "d1wse1"].map {
            PublicAPIPermission(host: "\($0).its.nv.gov", pathPrefixes: ["/renoxcd", "/vegasxcd", "/elko"],
                citation: .init(sourceType: .officialPost, url: URL(string: "https://www.nvroads.com/help/endpoint/cameras")!,
                    retrievedAt: Date(timeIntervalSince1970: 1_792_102_400)), permitsWowzaPlaceholder: true)
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
