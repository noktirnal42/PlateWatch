import Foundation

/// A privacy-safe aggregate of currently leased processing sessions. Presence
/// is intentionally not part of the sighting or CloudKit data model.
public struct PresenceAggregate: Codable, Sendable, Equatable {
    public var activeSessions: Int
    public var activeProcessors: Int
    public var processorsByFeed: [UUID: Int]
    public var generatedAt: Date

    public init(activeSessions: Int = 0, activeProcessors: Int = 0,
                processorsByFeed: [UUID: Int] = [:], generatedAt: Date = .now) {
        self.activeSessions = activeSessions
        self.activeProcessors = activeProcessors
        self.processorsByFeed = processorsByFeed
        self.generatedAt = generatedAt
    }
}

public struct PresenceHeartbeat: Codable, Sendable, Equatable {
    public var sessionID: String
    public var platform: String
    public var feedIDs: [UUID]
    public var activeProcessing: Bool

    public init(sessionID: String, platform: String, feedIDs: [UUID], activeProcessing: Bool) {
        self.sessionID = sessionID
        self.platform = platform
        self.feedIDs = feedIDs
        self.activeProcessing = activeProcessing
    }
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
