import Foundation

/// A privacy-safe aggregate of currently leased processing sessions. Presence
/// is intentionally not part of the sighting or CloudKit data model.
public struct PresenceAggregate: Codable, Sendable, Equatable {
    public var activeSessions: Int
    public var activeProcessors: Int
    public var processorsByFeed: [UUID: Int]
    public var generatedAt: Date
    /// Optional Hub-only counters. These are aggregate counts, never frame or
    /// sighting data, and are omitted when no Hub is reporting them.
    public var stats: PresenceStats?

    public init(activeSessions: Int = 0, activeProcessors: Int = 0,
                processorsByFeed: [UUID: Int] = [:], generatedAt: Date = .now,
                stats: PresenceStats? = nil) {
        self.activeSessions = activeSessions
        self.activeProcessors = activeProcessors
        self.processorsByFeed = processorsByFeed
        self.generatedAt = generatedAt
        self.stats = stats
    }
}

public struct PresenceStats: Codable, Sendable, Equatable {
    public var framesAnalyzed: Int
    public var publicFeedFrames: Int
    public var fleetHitsToday: Int
    public var skippedWhileBusy: Int
    public var outboxPending: Int

    public init(framesAnalyzed: Int = 0, publicFeedFrames: Int = 0,
                fleetHitsToday: Int = 0, skippedWhileBusy: Int = 0,
                outboxPending: Int = 0) {
        self.framesAnalyzed = max(0, framesAnalyzed)
        self.publicFeedFrames = max(0, publicFeedFrames)
        self.fleetHitsToday = max(0, fleetHitsToday)
        self.skippedWhileBusy = max(0, skippedWhileBusy)
        self.outboxPending = max(0, outboxPending)
    }
}

public struct PresenceHeartbeat: Codable, Sendable, Equatable {
    public var sessionID: String
    public var platform: String
    public var feedIDs: [UUID]
    public var activeProcessing: Bool
    public var stats: PresenceStats?

    public init(sessionID: String, platform: String, feedIDs: [UUID], activeProcessing: Bool,
                stats: PresenceStats? = nil) {
        self.sessionID = sessionID
        self.platform = platform
        // The server keeps at most 100 feed IDs per lease and rejects bodies over Vapor's 16 KB default
        // (HTTP 413). A Hub watching ~1,300 cameras sent ~50 KB and every heartbeat failed, so cap here, deterministically.
        self.feedIDs = Array(feedIDs.sorted { $0.uuidString < $1.uuidString }.prefix(Self.maxFeedIDs))
        self.activeProcessing = activeProcessing
        self.stats = stats
    }

    public static let maxFeedIDs = 100
}

/// REST presence client. The caller owns the opt-in setting and controls when
/// a heartbeat is sent; this type never starts a background timer on its own.
public struct PresenceClient: Sendable {
    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    public func heartbeat(_ payload: PresenceHeartbeat) async throws -> PresenceAggregate {
        let request = try JSONRequest.post(baseURL.appending(path: "v1/presence/heartbeat"))
        return try await request.send(payload, using: session)
    }

    public func release(sessionID: String) async throws -> PresenceAggregate {
        let request = try JSONRequest.post(baseURL.appending(path: "v1/presence/release"))
        return try await request.send(ReleasePresence(sessionID: sessionID), using: session)
    }

    public func aggregate() async throws -> PresenceAggregate {
        let request = try JSONRequest.get(baseURL.appending(path: "v1/presence"))
        return try await request.sendEmpty(using: session)
    }

    private struct ReleasePresence: Codable, Sendable {
        let sessionID: String
    }
}
