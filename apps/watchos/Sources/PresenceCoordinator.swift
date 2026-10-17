import Foundation
import PlateSync

/// Reports only that the companion is currently in use. The watch has no
/// camera or feed processor, so it never contributes to processor/feed counts.
@MainActor
final class WatchPresenceCoordinator {
    static let shared = WatchPresenceCoordinator()
    private let sessionID: String
    private var task: Task<Void, Never>?

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "presenceSessionID") {
            sessionID = saved
        } else {
            let created = UUID().uuidString.lowercased()
            UserDefaults.standard.set(created, forKey: "presenceSessionID")
            sessionID = created
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.heartbeat()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let id = sessionID
        Task { try? await PresenceClient(baseURL: SyncBackends.mirrorURL()).release(sessionID: id) }
    }

    /// Request an immediate aggregate refresh for the visible watch surface.
    /// This is intentionally the same heartbeat used by the background loop;
    /// it does not send frames, plates, locations, or evidence.
    func refreshNow() async {
        await heartbeat()
    }

    private func heartbeat() async {
        let payload = PresenceHeartbeat(sessionID: sessionID, platform: "watchOS",
                                        feedIDs: [], activeProcessing: false)
        if let aggregate = try? await PresenceClient(baseURL: SyncBackends.mirrorURL()).heartbeat(payload) {
            WatchComplicationStore.update(activeUsers: aggregate.activeSessions)
            WatchComplicationStore.updateLiveStats(
                activeSessions: aggregate.activeSessions,
                activeProcessors: aggregate.activeProcessors,
                framesAnalyzed: aggregate.stats?.framesAnalyzed,
                publicFeedFrames: aggregate.stats?.publicFeedFrames,
                fleetHitsToday: aggregate.stats?.fleetHitsToday,
                skippedWhileBusy: aggregate.stats?.skippedWhileBusy,
                outboxPending: aggregate.stats?.outboxPending,
                updatedAt: aggregate.generatedAt)
        } else {
            WatchComplicationStore.clearLiveStats()
        }
    }
}
