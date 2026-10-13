import CloudKit
import Foundation
import PlateKit
import PlateSync
import UserNotifications
import WatchKit

/// CloudKit silent-push wake handling (M4). The iOS app registers a
/// `CKQuerySubscription` on fleet-confirmed sightings; the system wakes this
/// extension with a background push, we pull the newest delta, match it
/// against the mirrored watchlist plates, and fire a haptic for hits.
final class WatchExtensionDelegate: NSObject, ObservableObject, WKExtensionDelegate {

    /// Recent watchlist hits, surfaced by the root view.
    @Published private(set) var hits: [WatchHit] = []

    struct WatchHit: Identifiable, Equatable {
        let id = UUID()
        var title: String
        var when: Date
    }

    private let backend = SyncBackends.makeDefault()

    /// watchOS silent-push entry point.
    func didReceiveRemoteNotification(_ remoteNotification: [AnyHashable: Any],
                                      withCompletion completionHandler: @escaping (WKBackgroundFetchResult) -> Void) {
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

    /// Watchlist items live in the paired-phone SwiftData store; the watch
    /// keeps a lightweight mirror in standard defaults, written by the
    /// phone app's watch connectivity sync (M4 follow-up).
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
