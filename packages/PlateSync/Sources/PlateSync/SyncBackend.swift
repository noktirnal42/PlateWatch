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

    /// Public agency directory used by the report-card surface.
    func agencies() async throws -> [PublicAgencyDTO]

    /// Aggregated public report for one agency. It contains no individual movement data.
    func agencyReport(id: UUID) async throws -> AgencyReportDTO

    /// A backend-specific handle that lets this device withdraw a submission later (CloudKit: the creator-owned record
    /// name). Stored on the local receipt at delivery time; nil when the backend needs no handle.
    func withdrawalHandle(for sighting: SightingSubmissionDTO, idempotencyKey: String) -> String?

    /// Withdraw a submission this device delivered. CloudKit deletes the creator-owned submission record; the reference
    /// server records a takedown request for moderators. Neither can retract a record a moderator already published
    /// from this device alone, and the outcome says so (`publicRecordMayRemain`).
    func withdraw(handle: String?, sightingID: UUID, moderationState: Sighting.ModerationState) async throws -> WithdrawalOutcome

    /// Register (or refresh) a watchlist-driven push subscription.
    /// No-op for REST deployments without push infrastructure.
    func ensureWatchlistSubscription() async throws

    /// k-anonymous heatmap/timeline. A requirement (not just an extension
    /// method) so a backend's own implementation — REST's server-side
    /// aggregate — is what `any SyncBackend` actually dispatches to.
    func heatmap(since: Date?, until: Date?, agencyID: UUID?) async throws -> HeatmapAggregateDTO
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

public struct PublicAgencyDTO: Sendable, Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var shortName: String?
    public var level: String
    public var parentAgencyID: UUID?
    public var publicContactURL: String?
    public var budgetURL: String?

    public init(id: UUID, name: String, shortName: String? = nil, level: String,
                parentAgencyID: UUID? = nil, publicContactURL: String? = nil,
                budgetURL: String? = nil) {
        self.id = id; self.name = name; self.shortName = shortName; self.level = level
        self.parentAgencyID = parentAgencyID; self.publicContactURL = publicContactURL
        self.budgetURL = budgetURL
    }
}

public struct AgencyReportDTO: Sendable, Codable, Equatable {
    public var agency: PublicAgencyDTO
    public var fleetSize: Int
    public var sightings30d: Int
    public var activeUnits: Int
    public var publicContactURL: String?
    public var budgetURL: String?
    public var generatedAt: Date

    public init(agency: PublicAgencyDTO, fleetSize: Int, sightings30d: Int,
                activeUnits: Int, publicContactURL: String? = nil,
                budgetURL: String? = nil, generatedAt: Date) {
        self.agency = agency; self.fleetSize = fleetSize; self.sightings30d = sightings30d
        self.activeUnits = activeUnits; self.publicContactURL = publicContactURL
        self.budgetURL = budgetURL; self.generatedAt = generatedAt
    }
}

/// What a withdrawal actually achieved, in words the UI can show without over-claiming.
public struct WithdrawalOutcome: Sendable, Equatable {
    public enum Kind: String, Sendable, Codable { case recordDeleted, takedownRequested }
    public var kind: Kind
    /// True when the submission may already have been published as a world-readable record that only a moderator can remove.
    public var publicRecordMayRemain: Bool
    public init(kind: Kind, publicRecordMayRemain: Bool) { self.kind = kind; self.publicRecordMayRemain = publicRecordMayRemain }

    public var message: String {
        switch kind {
        case .recordDeleted:
            return publicRecordMayRemain
                ? "Your submission was deleted. If it had already been published, a moderator must still remove the public record."
                : "Your submission was deleted from the backend."
        case .takedownRequested:
            return "A takedown request was sent. A moderator will review it; the sighting is hidden once they act."
        }
    }
}

public extension SyncBackend {
    func withdrawalHandle(for sighting: SightingSubmissionDTO, idempotencyKey: String) -> String? { nil }
    func withdraw(handle: String?, sightingID: UUID, moderationState: Sighting.ModerationState) async throws -> WithdrawalOutcome {
        throw SyncError.unsupported
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
    /// Unscoped aggregate convenience used by the public Explore surface.
    public func heatmap(since: Date?, until: Date?) async throws -> HeatmapAggregateDTO {
        try await heatmap(since: since, until: until, agencyID: nil)
    }

    /// Default: aggregate client-side from the public sightings feed
    /// (CloudKit serves records, not aggregates). Reads at most a few pages.
    public func heatmap(since: Date?, until: Date?, agencyID: UUID?) async throws -> HeatmapAggregateDTO {
        guard agencyID == nil else { throw SyncError.unsupported }
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
