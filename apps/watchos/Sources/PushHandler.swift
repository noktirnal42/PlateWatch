import CloudKit
import Foundation
import PlateKit
import PlateSync
import UserNotifications
import WatchKit
import WatchConnectivity

/// CloudKit silent-push wake handling (M4). The iOS app registers a
/// `CKQuerySubscription` on fleet-confirmed sightings; the system wakes this
/// extension with a background push, we pull the newest delta, match it
/// against the mirrored watchlist plates, and fire a haptic for hits.
final class WatchExtensionDelegate: NSObject, ObservableObject, WKApplicationDelegate, WCSessionDelegate {

    /// Recent watchlist hits, surfaced by the root view.
    @Published private(set) var hits: [WatchHit] = []
    @Published private(set) var unreadCount = 0

    struct WatchHit: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var when: Date
    }

    private let backend = SyncBackends.makeDefault()

    func applicationDidFinishLaunching() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        if let plates = session.applicationContext["watchlistPlates"] as? [String] {
            UserDefaults.standard.set(plates, forKey: "watchlistPlates")
        }
        WatchPresenceCoordinator.ingest(session.receivedApplicationContext)
        if let phosphor = session.receivedApplicationContext["phosphor"] as? String { UserDefaults.standard.set(phosphor, forKey: "pwPhosphor") }
    }

    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith activationState: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        WatchPresenceCoordinator.ingest(applicationContext)
        if let phosphor = applicationContext["phosphor"] as? String { UserDefaults.standard.set(phosphor, forKey: "pwPhosphor") }
        guard let plates = applicationContext["watchlistPlates"] as? [String] else { return }
        UserDefaults.standard.set(plates, forKey: "watchlistPlates")
    }

    /// watchOS silent-push entry point.
    func didReceiveRemoteNotification(_ remoteNotification: [AnyHashable: Any],
                                      fetchCompletionHandler completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
        Task {
            await evaluateNewest()
            completionHandler(self.hits.isEmpty ? .noData : .newData)
        }
    }

    /// Pull the latest page and check watchlist plates against it.
    @MainActor
    func evaluateNewest() async {
        guard let delta = try? await backend.pullSightings(since: nil) else { return }
        let plates = loadWatchlistPlates()
        guard !plates.isEmpty else { return }
        for sighting in WatchlistPullEvaluator.matchingPlates(in: delta.sightings, watchlist: plates) {
            let title = "\(Plate.normalize(sighting.plateText ?? "")) · \(sighting.unitNumber ?? "unit ?")"
            guard !hits.contains(where: { $0.title == title }) else { continue }
            hits.insert(WatchHit(title: title, when: sighting.capturedAt), at: 0)
            if hits.count > 20 { hits.removeLast(hits.count - 20) }
            unreadCount += 1
            WatchComplicationStore.update(fleetHits: hits.count)
            let current = WatchComplicationStore.liveStats()
            WatchComplicationStore.updateLiveStats(
                activeSessions: current.activeSessions ?? 0,
                activeProcessors: current.activeProcessors ?? 0,
                framesAnalyzed: current.framesAnalyzed,
                publicFeedFrames: current.publicFeedFrames,
                fleetHitsToday: max(current.fleetHitsToday ?? 0, hits.count),
                skippedWhileBusy: current.skippedWhileBusy,
                outboxPending: current.outboxPending,
                updatedAt: current.updatedAt ?? .now)
            hapticAlert(title: title)
        }
    }

    /// Haptic + (best-effort) local notification so the alert lands even
    /// when the wrist is down.
    private func hapticAlert(title: String) {
        WKInterfaceDevice.current().play(.notification)
        let content = UNMutableNotificationContent()
        content.title = "Watchlist hit"
        content.body = title
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Watchlist items live in the paired-phone SwiftData store; the phone
    /// sends a lightweight normalized mirror through WatchConnectivity and the
    /// watch keeps it in standard defaults for local matching.
    private func loadWatchlistPlates() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: "watchlistPlates") ?? [])
    }
}

/// Pure helper so matching logic stays testable without WK types.
enum WatchlistPullEvaluator {
    static func matchingPlates(in delta: [PublicSightingDTO], watchlist: Set<String>) -> [PublicSightingDTO] {
        delta.filter { sighting in
            guard let plate = sighting.plateText else { return false }
            return watchlist.contains(Plate.normalize(plate))
        }
    }
}
