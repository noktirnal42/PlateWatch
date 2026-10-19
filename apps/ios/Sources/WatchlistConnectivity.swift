import Foundation
import PlateKit
import PlateSync
import WatchConnectivity

/// Sends the local, operator-entered fleet watchlist to the paired watch.
/// Only normalized plate strings cross WatchConnectivity; no sightings,
/// images, locations, credentials or model output are mirrored.
final class WatchlistConnectivity: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchlistConnectivity()

    private override init() { super.init() }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    /// `updateApplicationContext` replaces the whole dictionary, so every sender merges into one retained copy.
    private let lock = NSLock()
    private var context: [String: Any] = [:]

    private func push(_ key: String, _ value: Any) {
        guard WCSession.isSupported() else { return }
        lock.lock(); context[key] = value; let snapshot = context; lock.unlock()
        try? WCSession.default.updateApplicationContext(snapshot)
    }

    func send(plates: [String]) {
        let normalized = Array(Set(plates.map(PlateKit.Plate.normalize))).sorted()
        push("watchlistPlates", normalized)
    }

    /// Aggregate counts only (sessions, processors, Hub dashboard totals). No identifiers, plates or frames.
    func send(presence aggregate: PresenceAggregate) {
        let s = aggregate.stats
        var dict: [String: Any] = ["activeSessions": aggregate.activeSessions, "activeProcessors": aggregate.activeProcessors,
                                   "generatedAt": aggregate.generatedAt.timeIntervalSince1970]
        if let s {
            dict["framesAnalyzed"] = s.framesAnalyzed; dict["publicFeedFrames"] = s.publicFeedFrames
            dict["fleetHitsToday"] = s.fleetHitsToday; dict["skippedWhileBusy"] = s.skippedWhileBusy; dict["outboxPending"] = s.outboxPending
        }
        push("presenceAggregate", dict)
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
#endif
}
