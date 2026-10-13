import Foundation

/// Scheduling state machine for one public feed. Pure logic — no I/O — so it
/// is unit-testable and usable by any transport (snapshot poller, HLS
/// session, future RTSP bridge).
///
/// Contract: single-flight per feed (one outstanding request), fetches never
/// closer together than `refreshInterval`, and failures back off
/// exponentially to a ceiling instead of hammering a public endpoint.
public struct FeedSchedule: Sendable, Equatable {
    public let refreshInterval: TimeInterval
    public private(set) var backoffMultiplier: Double
    public let maxBackoff: TimeInterval

    public private(set) var nextFetchAt: Date
    public private(set) var consecutiveFailures: Int

    public init(refreshInterval: TimeInterval,
                now: Date = Date(),
                backoffMultiplier: Double = 2.0,
                maxBackoff: TimeInterval = 300) {
        self.refreshInterval = max(refreshInterval, PublicFeedSource.minimumRefreshInterval)
        self.backoffMultiplier = backoffMultiplier
        self.maxBackoff = maxBackoff
        self.nextFetchAt = now
        self.consecutiveFailures = 0
    }

    /// Whether a fetch may start at `now` (callers decide single-flight).
    public func isDue(_ now: Date = Date()) -> Bool { now >= nextFetchAt }

    /// Record a successful fetch: next attempt at one refresh interval.
    public mutating func recordSuccess(now: Date = Date()) {
        consecutiveFailures = 0
        nextFetchAt = now.addingTimeInterval(refreshInterval)
    }

    /// Record a failure: exponential backoff, capped, never negative.
    public mutating func recordFailure(now: Date = Date()) {
        consecutiveFailures += 1
        let penalty = min(refreshInterval * pow(backoffMultiplier, Double(consecutiveFailures)),
                          maxBackoff)
        nextFetchAt = now.addingTimeInterval(penalty)
    }

    /// A feed that keeps failing is suspended after this many consecutive
    /// failures until a human re-enables it (fail-safe against dead URLs).
    public static let suspensionThreshold = 8

    public var isSuspended: Bool { consecutiveFailures >= Self.suspensionThreshold }
}

/// Transport-agnostic frame sink for feed ingest.
public protocol FeedFrameSink: Sendable {
    /// Called with a decoded frame and the feed it came from. Implementations
    /// run the analysis pipeline + RedactionGate; the feed never bypasses
    /// the gate.
    func accept(_ frameData: Data, from source: PublicFeedSource) async
}
