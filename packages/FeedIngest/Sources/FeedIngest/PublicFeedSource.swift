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
                termsNote: String = "") throws {
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
    }
}
