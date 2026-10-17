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
    private static let activeSessionsKey = "live.activeSessions"
    private static let activeProcessorsKey = "live.activeProcessors"
    private static let framesAnalyzedKey = "live.framesAnalyzed"
    private static let publicFeedFramesKey = "live.publicFeedFrames"
    private static let fleetHitsTodayKey = "live.fleetHitsToday"
    private static let skippedWhileBusyKey = "live.skippedWhileBusy"
    private static let outboxPendingKey = "live.outboxPending"
    private static let updatedAtKey = "live.updatedAt"

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

    static func updateLiveStats(activeSessions: Int, activeProcessors: Int,
                                framesAnalyzed: Int?, publicFeedFrames: Int?,
                                fleetHitsToday: Int?, skippedWhileBusy: Int?,
                                outboxPending: Int?, updatedAt: Date = .now) {
        defaults.set(max(0, activeSessions), forKey: activeSessionsKey)
        defaults.set(max(0, activeProcessors), forKey: activeProcessorsKey)
        setOptional(framesAnalyzed, forKey: framesAnalyzedKey)
        setOptional(publicFeedFrames, forKey: publicFeedFramesKey)
        setOptional(fleetHitsToday, forKey: fleetHitsTodayKey)
        setOptional(skippedWhileBusy, forKey: skippedWhileBusyKey)
        setOptional(outboxPending, forKey: outboxPendingKey)
        defaults.set(updatedAt, forKey: updatedAtKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }

    static func liveStats() -> WatchLiveStats {
        func optional(_ key: String) -> Int? {
            defaults.object(forKey: key) as? Int
        }
        return WatchLiveStats(activeSessions: optional(activeSessionsKey),
                              activeProcessors: optional(activeProcessorsKey),
                              framesAnalyzed: optional(framesAnalyzedKey),
                              publicFeedFrames: optional(publicFeedFramesKey),
                              fleetHitsToday: optional(fleetHitsTodayKey),
                              skippedWhileBusy: optional(skippedWhileBusyKey),
                              outboxPending: optional(outboxPendingKey),
                              updatedAt: defaults.object(forKey: updatedAtKey) as? Date)
    }

    private static func setOptional(_ value: Int?, forKey key: String) {
        if let value { defaults.set(max(0, value), forKey: key) }
        else { defaults.removeObject(forKey: key) }
    }
}

struct WatchLiveStats: Equatable {
    var activeSessions: Int?
    var activeProcessors: Int?
    var framesAnalyzed: Int?
    var publicFeedFrames: Int?
    var fleetHitsToday: Int?
    var skippedWhileBusy: Int?
    var outboxPending: Int?
    var updatedAt: Date?
}
