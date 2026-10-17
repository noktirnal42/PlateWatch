import Foundation
import Vapor

struct PresenceHeartbeat: Content, Sendable {
    var sessionID: String
    var platform: String
    var feedIDs: [UUID]
    var activeProcessing: Bool
    var stats: PresenceStats?
}

struct PresenceStats: Content, Sendable, Equatable {
    var framesAnalyzed: Int
    var publicFeedFrames: Int
    var fleetHitsToday: Int
    var skippedWhileBusy: Int
    var outboxPending: Int
}

struct PresenceAggregate: Content, Sendable, Equatable {
    var activeSessions: Int
    var activeProcessors: Int
    var processorsByFeed: [UUID: Int]
    var generatedAt: Date
    var stats: PresenceStats?
}

/// Ephemeral operator presence. Leases are deliberately process-local and
/// expire quickly; they are never written to Postgres, CloudKit, or audit log.
actor PresenceStore {
    struct Lease: Sendable {
        var platform: String
        var feedIDs: Set<UUID>
        var activeProcessing: Bool
        var expiresAt: Date
        var stats: PresenceStats?
    }

    private var leases: [String: Lease] = [:]
    private let ttl: TimeInterval = 90

    func heartbeat(_ payload: PresenceHeartbeat, now: Date = .now) -> PresenceAggregate {
        let cleanFeeds = Set(payload.feedIDs.prefix(100))
        // Only a Hub may publish its local dashboard counters. Other clients
        // contribute presence/processors, but cannot spoof processing totals.
        let cleanStats = payload.platform == "macOS-hub" ? payload.stats.map(Self.sanitize) : nil
        leases[payload.sessionID] = Lease(platform: String(payload.platform.prefix(32)),
                                          feedIDs: cleanFeeds,
                                          activeProcessing: payload.activeProcessing,
                                          expiresAt: now.addingTimeInterval(ttl),
                                          stats: cleanStats)
        return aggregate(now: now)
    }

    func release(_ sessionID: String, now: Date = .now) -> PresenceAggregate {
        leases.removeValue(forKey: sessionID)
        return aggregate(now: now)
    }

    func aggregate(now: Date = .now) -> PresenceAggregate {
        leases = leases.filter { $0.value.expiresAt > now }
        var feedCounts: [UUID: Int] = [:]
        var processors = 0
        var stats: PresenceStats?
        for lease in leases.values where lease.activeProcessing {
            processors += 1
            for id in lease.feedIDs { feedCounts[id, default: 0] += 1 }
            if let leaseStats = lease.stats {
                if stats == nil { stats = PresenceStats(framesAnalyzed: 0, publicFeedFrames: 0, fleetHitsToday: 0, skippedWhileBusy: 0, outboxPending: 0) }
                stats?.framesAnalyzed += leaseStats.framesAnalyzed
                stats?.publicFeedFrames += leaseStats.publicFeedFrames
                stats?.fleetHitsToday += leaseStats.fleetHitsToday
                stats?.skippedWhileBusy += leaseStats.skippedWhileBusy
                stats?.outboxPending += leaseStats.outboxPending
            }
        }
        return PresenceAggregate(activeSessions: leases.count,
                                 activeProcessors: processors,
                                 processorsByFeed: feedCounts,
                                 generatedAt: now,
                                 stats: stats)
    }

    private static func sanitize(_ value: PresenceStats) -> PresenceStats {
        let cap = 100_000_000
        return PresenceStats(framesAnalyzed: min(max(0, value.framesAnalyzed), cap),
                             publicFeedFrames: min(max(0, value.publicFeedFrames), cap),
                             fleetHitsToday: min(max(0, value.fleetHitsToday), cap),
                             skippedWhileBusy: min(max(0, value.skippedWhileBusy), cap),
                             outboxPending: min(max(0, value.outboxPending), cap))
    }
}

struct PresenceController: RouteCollection {
    let store: PresenceStore

    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        v1.grouped("presence", "heartbeat").post(use: heartbeat)
        v1.grouped("presence", "release").post(use: release)
        v1.grouped("presence").get(use: aggregate)
    }

    @Sendable
    func heartbeat(req: Request) async throws -> PresenceAggregate {
        let payload = try req.content.decode(PresenceHeartbeat.self)
        try Self.validate(payload)
        return await store.heartbeat(payload)
    }

    @Sendable
    func release(req: Request) async throws -> PresenceAggregate {
        struct Body: Decodable { let sessionID: String }
        let body = try req.content.decode(Body.self)
        guard Self.validSessionID(body.sessionID) else {
            throw Abort(.badRequest, reason: "invalid sessionID")
        }
        return await store.release(body.sessionID)
    }

    @Sendable
    func aggregate(req: Request) async throws -> PresenceAggregate {
        await store.aggregate()
    }

    private static func validate(_ payload: PresenceHeartbeat) throws {
        guard validSessionID(payload.sessionID), !payload.platform.isEmpty,
              payload.platform.count <= 32 else {
            throw Abort(.badRequest, reason: "invalid presence payload")
        }
    }

    private static func validSessionID(_ id: String) -> Bool {
        id.count >= 16 && id.count <= 128 && id.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
    }
}
