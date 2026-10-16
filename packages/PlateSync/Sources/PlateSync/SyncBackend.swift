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

    /// k-anonymous heatmap/timeline. A requirement (not just an extension
    /// method) so a backend's own implementation — REST's server-side
    /// aggregate — is what `any SyncBackend` actually dispatches to.
    func heatmap(since: Date?, until: Date?) async throws -> HeatmapAggregateDTO
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
    /// Optional audit metadata. Older backends may omit these fields.
    public var idempotencyKey: String?
    public var operatorConfirmed: Bool?

    public init(sightingID: UUID, moderationState: Sighting.ModerationState,
                serverReceivedAt: Date, idempotencyKey: String? = nil,
                operatorConfirmed: Bool? = nil) {
        self.sightingID = sightingID
        self.moderationState = moderationState
        self.serverReceivedAt = serverReceivedAt
        self.idempotencyKey = idempotencyKey
        self.operatorConfirmed = operatorConfirmed
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

/// Builds the same k-anonymous aggregate the reference server serves, from
/// public sightings the client has already pulled. Cells and days with fewer
/// than `k` fleet-confirmed sightings are withheld and only counted.
public enum HeatmapAggregator {
    public static let defaultK = 5

    public static func aggregate(_ sightings: [PublicSightingDTO], k: Int = defaultK,
                                 since: Date, until: Date) -> HeatmapAggregateDTO {
        let inWindow = sightings.filter { $0.capturedAt >= since && $0.capturedAt <= until }

        var cellCounts: [String: Int] = [:]
        for s in inWindow where !s.geohash6.isEmpty { cellCounts[s.geohash6, default: 0] += 1 }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        var dayCounts: [String: Int] = [:]
        for s in inWindow { dayCounts[formatter.string(from: s.capturedAt), default: 0] += 1 }

        let cells = cellCounts.filter { $0.value >= k }
            .map { HeatmapAggregateDTO.Cell(geohash6: $0.key, count: $0.value) }
            .sorted { ($0.count, $1.geohash6) > ($1.count, $0.geohash6) }
        let days = dayCounts.filter { $0.value >= k }
            .map { HeatmapAggregateDTO.Day(date: $0.key, count: $0.value) }
            .sorted { $0.date < $1.date }
        return HeatmapAggregateDTO(
            k: k, since: since, until: until, cells: cells, timeline: days,
            withheldCells: cellCounts.count - cells.count,
            withheldDays: dayCounts.count - days.count)
    }
}

extension SyncBackend {
    /// Default: aggregate client-side from the public sightings feed
    /// (CloudKit serves records, not aggregates). Reads at most a few pages.
    public func heatmap(since: Date?, until: Date?) async throws -> HeatmapAggregateDTO {
        let end = until ?? Date()
        let start = since ?? end.addingTimeInterval(-30 * 86_400)
        var all: [PublicSightingDTO] = []
        var cursor: SyncCursor?
        for _ in 0..<5 {
            let delta = try await pullSightings(since: cursor)
            all.append(contentsOf: delta.sightings)
            guard let next = delta.newCursor, next != cursor, !delta.sightings.isEmpty else { break }
            cursor = next
        }
        return HeatmapAggregator.aggregate(all, since: start, until: end)
    }
}
