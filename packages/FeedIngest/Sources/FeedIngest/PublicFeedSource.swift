import Foundation
import PlateKit

/// A published public camera feed (state 511 traffic cam, port/transit cam).
/// USA first. Every source carries a citation for where the feed URL came
/// from; frames produced from it inherit that citation. All persistence
/// rules are unchanged — the `RedactionGate` decides what a frame may
/// become, exactly like a handheld capture (docs/CAMERA-SOURCES.md).
public struct PublicFeedSource: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var url: URL
    public var kind: Kind
    /// Seconds between polls. Pollers must never fetch faster than this —
    /// it is a floor, not a target.
    public var refreshInterval: TimeInterval
    /// Geohash-6 of the camera's own (fixed) location.
    public var geohash6: String
    public var citation: SourceCitation
    /// Optional honoring note, e.g. "Caltrans public feed, 5 s cadence".
    public var termsNote: String
    /// US state (or province) the camera belongs to, as recorded by the
    /// catalogue import. Drives the feed list's state grouping; nil for
    /// sources imported before the field existed until they are re-imported.
    public var state: String?
    /// Recorded terms (docs/FEED-SOURCES.md §5). Defaults to "unknown, not allowed".
    public var terms: FeedTerms
    /// Native image long side in pixels, when the catalogue states it (picks the analysis tier).
    public var nativeLongSide: Int?
    public var locationConfidence: LocationConfidence

    /// A source may be analysed only after a human confirmed its terms: terms page + date recorded,
    /// `automatedUseAllowed` set, and a licence class that is not `askFirst`/`unknown`.
    public var mayBeAnalysed: Bool {
        terms.automatedUseAllowed && terms.termsURL != nil && terms.termsReadOn != nil
            && terms.licenseClass != .askFirst && terms.licenseClass != .unknown
    }

    /// Identity inference needs a trustworthy camera position.
    public var mayResolveIdentity: Bool { locationConfidence != .unknown }

    /// The tier for a received frame: its actual size wins over the catalogue's claim.
    public func analysisTier(frameLongSide: Int?) -> AnalysisTier {
        AnalysisTier.tier(forLongSide: frameLongSide ?? nativeLongSide ?? 0)
    }

    public enum Kind: String, Sendable, Codable {
        /// A JPEG endpoint that serves the current frame per request
        /// (AXIS-style snapshot). Most common on DOT portals.
        case snapshotJPEG
        /// Live HLS stream (.m3u8) — decode with AVPlayerItemVideoOutput.
        case hls
        /// RTSP — requires the VLCKit fallback path; unsupported natively.
        case rtsp
    }

    public enum CreationError: Error, Equatable {
        case missingCitation
        case refreshIntervalTooAggressive
        case invalidGeohash
    }

    /// Polling floor: public feeds are somebody's bandwidth; the fastest
    /// published cadence in common DOT catalogs is 1 s and most are ≥ 5 s.
    public static let minimumRefreshInterval: TimeInterval = 1.0

    public init(id: UUID = UUID(),
                name: String,
                url: URL,
                kind: Kind,
                refreshInterval: TimeInterval,
                geohash6: String,
                citation: SourceCitation,
                termsNote: String = "",
                state: String? = nil,
                terms: FeedTerms = .unknown,
                nativeLongSide: Int? = nil,
                locationConfidence: LocationConfidence = .approximate) throws {
        guard refreshInterval >= Self.minimumRefreshInterval else {
            throw CreationError.refreshIntervalTooAggressive
        }
        guard geohash6.count == 6 else {
            throw CreationError.invalidGeohash
        }
        self.id = id
        self.name = name
        self.url = url
        self.kind = kind
        self.refreshInterval = refreshInterval
        self.geohash6 = geohash6
        self.citation = citation
        self.termsNote = termsNote
        self.state = state
        self.terms = terms
        self.nativeLongSide = nativeLongSide
        self.locationConfidence = locationConfidence
    }

    // Older saved catalogues have none of the newer keys: decode them with safe defaults.
    private enum CodingKeys: String, CodingKey {
        case id, name, url, kind, refreshInterval, geohash6, citation, termsNote, state, terms, nativeLongSide, locationConfidence
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        url = try c.decode(URL.self, forKey: .url)
        kind = try c.decode(Kind.self, forKey: .kind)
        refreshInterval = try c.decode(TimeInterval.self, forKey: .refreshInterval)
        geohash6 = try c.decode(String.self, forKey: .geohash6)
        citation = try c.decode(SourceCitation.self, forKey: .citation)
        termsNote = try c.decodeIfPresent(String.self, forKey: .termsNote) ?? ""
        state = try c.decodeIfPresent(String.self, forKey: .state)
        terms = try c.decodeIfPresent(FeedTerms.self, forKey: .terms) ?? .unknown
        nativeLongSide = try c.decodeIfPresent(Int.self, forKey: .nativeLongSide)
        locationConfidence = try c.decodeIfPresent(LocationConfidence.self, forKey: .locationConfidence) ?? .approximate
    }
}
