import Foundation
import PlateKit
import PlateSync
import UIKit
import UserNotifications

/// Silent CloudKit push handling on the phone (M4). The fleet-hits query
/// subscription wakes the app in the background; we pull the newest delta,
/// match mirrored watchlist plates, and post a local notification for hits.
/// The watch mirrors its own copy via UserDefaults for its haptic path.
final class AppDelegate: NSObject, UIApplicationDelegate {
    private let backend = SyncBackends.makeDefault()
    private let notificationDelegate = ForegroundPresenter()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = notificationDelegate
        // Notification permission is requested in context — when the user adds
        // their first watchlist plate — not as a cold prompt at launch.
        return true
    }

    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Task {
            let hadHit = await self.evaluateNewest()
            completionHandler(hadHit ? .newData : .noData)
        }
    }

    @MainActor
    private func evaluateNewest() async -> Bool {
        guard let delta = try? await backend.pullSightings(since: nil) else { return false }
        let plates = Set(UserDefaults.standard.stringArray(forKey: "watchlistPlates") ?? [])
        guard !plates.isEmpty else { return false }
        var hit = false
        for sighting in delta.sightings where matchesWatchlist(sighting, plates: plates) {
            hit = true
            let content = UNMutableNotificationContent()
            content.title = "Watchlist hit"
            content.body = "\(Plate.normalize(sighting.plateText ?? "")) · \(sighting.unitNumber ?? "unit ?")"
            content.sound = .default
            let request = UNNotificationRequest(identifier: UUID().uuidString,
                                                content: content, trigger: nil)
            try? await UNUserNotificationCenter.current().add(request)
        }
        return hit
    }

    // Foreground presentation so alerts are visible while the app is up.
    private final class ForegroundPresenter: NSObject, UNUserNotificationCenterDelegate {
        func userNotificationCenter(_ center: UNUserNotificationCenter,
                                    willPresent notification: UNNotification,
                                    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
            completionHandler([.banner, .sound])
        }
    }
}

private func matchesWatchlist(_ sighting: PublicSightingDTO, plates: Set<String>) -> Bool {
    guard let plate = sighting.plateText else { return false }
    return plates.contains(Plate.normalize(plate))
}

/// Asks for notification permission once, at the moment it is useful.
enum NotificationPermission {
    static func requestIfNeeded() {
        Task {
            let center = UNUserNotificationCenter.current()
            let settings = await center.notificationSettings()
            guard settings.authorizationStatus == .notDetermined else { return }
            _ = try? await center.requestAuthorization(options: [.alert, .sound])
        }
    }
}
