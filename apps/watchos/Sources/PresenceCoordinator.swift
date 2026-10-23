import Foundation
import WatchConnectivity

/// The watch has no route to the presence backend (and never contributes a lease of its own). It shows the aggregate the
/// paired iPhone reads from CloudKit and relays over WatchConnectivity (`presenceAggregate`: counts only).
/// With the phone out of reach or presence switched off, the stats stay "—" rather than showing stale numbers.
@MainActor
final class WatchPresenceCoordinator {
    static let shared = WatchPresenceCoordinator()
    private init() {}

    func start() { Task { await refreshNow() } }
    func stop() {}

    /// Re-reads the most recent aggregate the phone delivered.
    func refreshNow() async {
        guard WCSession.isSupported() else { WatchComplicationStore.clearLiveStats(); return }
        apply(Snapshot(WCSession.default.receivedApplicationContext["presenceAggregate"] as? [String: Any]))
    }

    /// Plain values copied out of the WatchConnectivity dictionary so nothing non-Sendable crosses actors.
    struct Snapshot: Sendable {
        var sessions: Int, processors: Int, generated: TimeInterval
        var frames: Int?, feedFrames: Int?, hits: Int?, skipped: Int?, outbox: Int?
        init?(_ d: [String: Any]?) {
            guard let d, let s = d["activeSessions"] as? Int, let p = d["activeProcessors"] as? Int,
                  let g = d["generatedAt"] as? TimeInterval else { return nil }
            sessions = s; processors = p; generated = g
            frames = d["framesAnalyzed"] as? Int; feedFrames = d["publicFeedFrames"] as? Int
            hits = d["fleetHitsToday"] as? Int; skipped = d["skippedWhileBusy"] as? Int; outbox = d["outboxPending"] as? Int
        }
    }

    /// Called for the launch-time context and for every later delivery.
    nonisolated static func ingest(_ context: [String: Any]) {
        let snapshot = Snapshot(context["presenceAggregate"] as? [String: Any])
        Task { @MainActor in shared.apply(snapshot) }
    }

    private func apply(_ snapshot: Snapshot?) {
        guard let s = snapshot, Date().timeIntervalSince(Date(timeIntervalSince1970: s.generated)) < 10 * 60 else {
            WatchComplicationStore.clearLiveStats(); return
        }
        WatchComplicationStore.update(activeUsers: s.sessions)
        WatchComplicationStore.updateLiveStats(
            activeSessions: s.sessions, activeProcessors: s.processors,
            framesAnalyzed: s.frames, publicFeedFrames: s.feedFrames, fleetHitsToday: s.hits,
            skippedWhileBusy: s.skipped, outboxPending: s.outbox, updatedAt: Date(timeIntervalSince1970: s.generated))
    }
}
