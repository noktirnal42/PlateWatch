import Foundation
import WidgetKit

/// Small, privacy-safe bridge between the watch app and its complication.
/// Only aggregate counts are shared; no plates, images, or locations leave the
/// watch process through this store.
enum WatchComplicationStore {
    static let suiteName = "group.org.platewatch.watch"
    static let kind = "PlateWatchComplication"
    private static let fleetHitsKey = "complication.fleetHits"
    private static let activeUsersKey = "complication.activeUsers"

    private static var defaults: UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    static func fleetHitCount() -> Int {
        max(0, defaults.integer(forKey: fleetHitsKey))
    }

    static func activeUserCount() -> Int? {
        guard defaults.object(forKey: activeUsersKey) != nil else { return nil }
        return max(0, defaults.integer(forKey: activeUsersKey))
    }

    static func update(fleetHits: Int? = nil, activeUsers: Int?? = nil) {
        if let fleetHits {
            defaults.set(max(0, fleetHits), forKey: fleetHitsKey)
        }
        if let activeUsers {
            if let activeUsers {
                defaults.set(max(0, activeUsers), forKey: activeUsersKey)
            } else {
                defaults.removeObject(forKey: activeUsersKey)
            }
        }
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
