import CloudKit
import CryptoKit
import Foundation

/// What every presence transport provides. The REST reference server and CloudKit both implement it, so Hub, iPhone
/// and (through a phone relay) watch share one code path.
public protocol PresenceService: Sendable {
    func heartbeat(_ payload: PresenceHeartbeat) async throws -> PresenceAggregate
    func release(sessionID: String) async throws -> PresenceAggregate
    func aggregate() async throws -> PresenceAggregate
}

extension PresenceClient: PresenceService {}

public enum PresenceServices {
    /// CloudKit when this binary is entitled for it (signed Hub / iPhone), otherwise the REST mirror (simulator, dev).
    /// Never traps: `cloudKitAvailable()` is checked before a container is constructed.
    public static func makeDefault() -> any PresenceService {
        SyncBackends.cloudKitAvailable() ? CloudKitPresenceClient() : PresenceClient(baseURL: SyncBackends.mirrorURL())
    }
}

public enum PresenceError: Error, LocalizedError, Sendable, Equatable {
    case schemaNotDeployed
    case notSignedIn
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .schemaNotDeployed: "CloudKit presence schema is not deployed (record type PresenceLease)"
        case .notSignedIn: "Sign in to iCloud to share or read live counts"
        case .unavailable(let reason): reason
        }
    }

    /// A short, user-facing status for dashboards.
    public var statusText: String {
        switch self {
        case .schemaNotDeployed: "Offline · CloudKit schema not deployed"
        case .notSignedIn: "Offline · iCloud sign-in needed"
        case .unavailable: "Offline · local processing continues"
        }
    }
}

/// One anonymous, short-lived lease as stored in CloudKit. `recordName` is a hash of the random install-local session
/// id, so the same install overwrites one record (the table stays bounded by installs) and the raw id is never published.
public struct PresenceLease: Sendable, Equatable {
    public static let recordType = "PresenceLease"
    public static let ttl: TimeInterval = 120   // heartbeats every 45 s; a crash disappears within two minutes

    public var platform: String
    public var feedIDs: [UUID]
    public var activeProcessing: Bool
    public var expiresAt: Date
    public var stats: PresenceStats?

    public init(platform: String, feedIDs: [UUID], activeProcessing: Bool, expiresAt: Date, stats: PresenceStats? = nil) {
        self.platform = platform; self.feedIDs = feedIDs; self.activeProcessing = activeProcessing
        self.expiresAt = expiresAt; self.stats = stats
    }

    public static func recordName(forSessionID id: String) -> String {
        "lease-" + SHA256.hash(data: Data(("platewatch-presence|" + id).utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
    }

    public init(heartbeat: PresenceHeartbeat, now: Date = .now) {
        self.init(platform: String(heartbeat.platform.prefix(32)), feedIDs: heartbeat.feedIDs,
                  activeProcessing: heartbeat.activeProcessing, expiresAt: now.addingTimeInterval(Self.ttl),
                  // Only a Hub reports dashboard counters; others cannot contribute processing totals.
                  stats: heartbeat.platform == "macOS-hub" ? heartbeat.stats : nil)
    }

    public func fill(_ record: CKRecord) {
        record["platform"] = platform
        record["activeProcessing"] = activeProcessing ? 1 : 0
        record["feedIDs"] = feedIDs.prefix(PresenceHeartbeat.maxFeedIDs).map(\.uuidString)
        record["expiresAt"] = expiresAt
        record["framesAnalyzed"] = stats?.framesAnalyzed
        record["publicFeedFrames"] = stats?.publicFeedFrames
        record["fleetHitsToday"] = stats?.fleetHitsToday
        record["skippedWhileBusy"] = stats?.skippedWhileBusy
        record["outboxPending"] = stats?.outboxPending
    }

    public init?(record: CKRecord) {
        guard record.recordType == Self.recordType, let platform = record["platform"] as? String,
              let expires = record["expiresAt"] as? Date else { return nil }
        let ids = (record["feedIDs"] as? [String] ?? []).prefix(PresenceHeartbeat.maxFeedIDs).compactMap(UUID.init(uuidString:))
        var stats: PresenceStats?
        if let frames = record["framesAnalyzed"] as? Int {
            stats = PresenceStats(framesAnalyzed: frames, publicFeedFrames: record["publicFeedFrames"] as? Int ?? 0,
                                  fleetHitsToday: record["fleetHitsToday"] as? Int ?? 0,
                                  skippedWhileBusy: record["skippedWhileBusy"] as? Int ?? 0,
                                  outboxPending: record["outboxPending"] as? Int ?? 0)
        }
        self.init(platform: String(platform.prefix(32)), feedIDs: ids, activeProcessing: (record["activeProcessing"] as? Int ?? 0) == 1,
                  expiresAt: expires, stats: platform == "macOS-hub" ? stats : nil)
    }
}

public enum PresenceAggregator {
    /// Counts unexpired leases. Stats are summed from Hub leases only and clamped; a public database cannot stop a
    /// forged lease, so these remain **live estimates**, never audited figures.
    public static func aggregate(_ leases: [PresenceLease], now: Date = .now) -> PresenceAggregate {
        let live = leases.filter { $0.expiresAt > now }
        var byFeed: [UUID: Int] = [:]
        var processors = 0
        var stats: PresenceStats?
        let cap = 100_000_000
        for lease in live where lease.activeProcessing {
            processors += 1
            for id in lease.feedIDs.prefix(PresenceHeartbeat.maxFeedIDs) { byFeed[id, default: 0] += 1 }
            if let s = lease.stats {
                var total = stats ?? PresenceStats()
                total.framesAnalyzed = min(cap, total.framesAnalyzed + s.framesAnalyzed)
                total.publicFeedFrames = min(cap, total.publicFeedFrames + s.publicFeedFrames)
                total.fleetHitsToday = min(cap, total.fleetHitsToday + s.fleetHitsToday)
                total.skippedWhileBusy = min(cap, total.skippedWhileBusy + s.skippedWhileBusy)
                total.outboxPending = min(cap, total.outboxPending + s.outboxPending)
                stats = total
            }
        }
        return PresenceAggregate(activeSessions: live.count, activeProcessors: processors, processorsByFeed: byFeed,
                                 generatedAt: now, stats: stats)
    }
}

/// CloudKit public-database presence. See `cloudkit/schema.ckdb` (`PresenceLease`) and docs/PRESENCE-DESIGN.md.
public struct CloudKitPresenceClient: PresenceService {
    private let container: CKContainer
    private var database: CKDatabase { container.publicCloudDatabase }

    public init(containerIdentifier: String = SyncBackends.containerID) {
        container = CKContainer(identifier: containerIdentifier)
    }

    public func heartbeat(_ payload: PresenceHeartbeat) async throws -> PresenceAggregate {
        let id = CKRecord.ID(recordName: PresenceLease.recordName(forSessionID: payload.sessionID))
        let record = CKRecord(recordType: PresenceLease.recordType, recordID: id)
        PresenceLease(heartbeat: payload).fill(record)
        do {
            // `.allKeys` replaces our own previous lease without a fetch round trip.
            _ = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .allKeys)
        } catch { throw Self.map(error) }
        return try await aggregate()
    }

    public func release(sessionID: String) async throws -> PresenceAggregate {
        do {
            _ = try await database.modifyRecords(saving: [], deleting: [CKRecord.ID(recordName: PresenceLease.recordName(forSessionID: sessionID))])
        } catch { throw Self.map(error) }
        return try await aggregate()
    }

    public func aggregate() async throws -> PresenceAggregate {
        let now = Date.now
        let query = CKQuery(recordType: PresenceLease.recordType, predicate: NSPredicate(format: "expiresAt > %@", now as NSDate))
        do {
            let (results, _) = try await database.records(matching: query, resultsLimit: 400)
            let leases = results.compactMap { try? $0.1.get() }.compactMap(PresenceLease.init(record:))
            return PresenceAggregator.aggregate(leases, now: now)
        } catch { throw Self.map(error) }
    }

    static func map(_ error: Error) -> PresenceError {
        guard let ck = error as? CKError else { return .unavailable(error.localizedDescription) }
        switch ck.code {
        case .unknownItem, .invalidArguments: return .schemaNotDeployed
        case .notAuthenticated, .permissionFailure: return .notSignedIn
        default: return .unavailable(ck.localizedDescription)
        }
    }
}
