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
}
