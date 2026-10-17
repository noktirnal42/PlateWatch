import Foundation
import Vapor

struct PresenceHeartbeat: Content, Sendable {
    var sessionID: String
    var platform: String
    var feedIDs: [UUID]
    var activeProcessing: Bool
}

struct PresenceAggregate: Content, Sendable, Equatable {
    var activeSessions: Int
    var activeProcessors: Int
    var processorsByFeed: [UUID: Int]
    var generatedAt: Date
}

/// Ephemeral operator presence. Leases are deliberately process-local and
/// expire quickly; they are never written to Postgres, CloudKit, or audit log.
actor PresenceStore {
    struct Lease: Sendable {
        var platform: String
        var feedIDs: Set<UUID>
        var activeProcessing: Bool
        var expiresAt: Date
    }

    private var leases: [String: Lease] = [:]
    private let ttl: TimeInterval = 90

    func heartbeat(_ payload: PresenceHeartbeat, now: Date = .now) -> PresenceAggregate {
        let cleanFeeds = Set(payload.feedIDs.prefix(100))
        leases[payload.sessionID] = Lease(platform: String(payload.platform.prefix(32)),
                                          feedIDs: cleanFeeds,
                                          activeProcessing: payload.activeProcessing,
                                          expiresAt: now.addingTimeInterval(ttl))
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
        for lease in leases.values where lease.activeProcessing {
            processors += 1
            for id in lease.feedIDs { feedCounts[id, default: 0] += 1 }
        }
        return PresenceAggregate(activeSessions: leases.count,
                                 activeProcessors: processors,
                                 processorsByFeed: feedCounts,
                                 generatedAt: now)
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
