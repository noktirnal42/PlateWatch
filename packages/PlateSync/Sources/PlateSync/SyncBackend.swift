import Foundation
import PlateKit

/// The only network boundary in the platform. Two shipping conformances:
/// `CloudKitBackend` (default, free-tier) and `RESTBackend` (cross-platform
/// reference protocol).
public protocol SyncBackend: Sendable {
    /// Submit a redacted, gate-approved sighting. Idempotent by
    /// `idempotencyKey` (SHA-256 of sighting content + device key id) so
    /// outbox retries are safe.
    func submit(_ sighting: SightingSubmissionDTO,
                idempotencyKey: String) async throws -> SubmissionReceipt

    /// Pull sightings newer than a cursor (CloudKit change token / REST
    /// cursor). Delta-only — never full-table scans.
    func pullSightings(since cursor: SyncCursor?) async throws -> SightingDelta

    /// Resolve vehicles matching a plate text (public read).
    func vehicles(matchingPlate plateText: String) async throws -> [PublicVehicleDTO]

    /// Register (or refresh) a watchlist-driven push subscription.
    /// No-op for REST deployments without push infrastructure.
    func ensureWatchlistSubscription() async throws
}

public struct SyncCursor: Sendable, Codable, Equatable {
    public var token: String
    public init(token: String) { self.token = token }
}

public struct SightingDelta: Sendable {
    public var sightings: [PublicSightingDTO]
    public var newCursor: SyncCursor?
    public init(sightings: [PublicSightingDTO], newCursor: SyncCursor?) {
        self.sightings = sightings
        self.newCursor = newCursor
    }
}

public struct SubmissionReceipt: Sendable, Codable, Equatable {
    public var sightingID: UUID
    public var moderationState: Sighting.ModerationState
    public var serverReceivedAt: Date

    public init(sightingID: UUID, moderationState: Sighting.ModerationState,
                serverReceivedAt: Date) {
        self.sightingID = sightingID
        self.moderationState = moderationState
        self.serverReceivedAt = serverReceivedAt
    }
}

public enum SyncError: Error {
    case notAuthenticated
    case quotaExceeded          // back off; free tier protection
    case serverRejected(reason: String)
    case offline
    case unsupported            // backend cannot serve this call
}

/// k-anonymous aggregate of fleet-confirmed sightings, mirroring the
/// reference server's `GET /v1/aggregates/heatmap`. Buckets under k are
/// withheld server-side — the client never sees sub-k counts.
public struct HeatmapAggregateDTO: Sendable, Codable, Equatable {
    public struct Cell: Sendable, Codable, Equatable {
        public var geohash6: String
        public var count: Int
        public init(geohash6: String, count: Int) {
            self.geohash6 = geohash6
            self.count = count
        }
    }

    public struct Day: Sendable, Codable, Equatable {
        public var date: String   // yyyy-MM-dd UTC
        public var count: Int
        public init(date: String, count: Int) {
            self.date = date
            self.count = count
        }
    }

    public var k: Int
    public var since: Date
    public var until: Date
    public var cells: [Cell]
    public var timeline: [Day]
    public var withheldCells: Int
    public var withheldDays: Int

    public init(k: Int, since: Date, until: Date,
                cells: [Cell], timeline: [Day],
                withheldCells: Int, withheldDays: Int) {
        self.k = k
        self.since = since
        self.until = until
        self.cells = cells
        self.timeline = timeline
        self.withheldCells = withheldCells
        self.withheldDays = withheldDays
    }
}

extension SyncBackend {
    /// k-anonymous heatmap/timeline aggregate. Default: unsupported
    /// (CloudKit serves records, not aggregates — REST deployments do).
    public func heatmap(since: Date?, until: Date?) async throws -> HeatmapAggregateDTO {
        throw SyncError.unsupported
    }
}
