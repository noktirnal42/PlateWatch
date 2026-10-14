import Foundation

/// Suppresses repeat sightings of the same vehicle at the same camera. A parked police car is in every frame a
/// fixed camera produces; without this each poll would log a new sighting (measured: a static test frame produced
/// 10 sightings in 10 polls). One sighting per key per `window`; a vehicle that stays longer is re-recorded once per
/// window, so dwell time stays visible without flooding the outbox. Pure logic, in-memory only.
public struct SightingDeduper: Sendable {
    public let window: TimeInterval
    public let maxEntries: Int
    private var lastRecorded: [String: Date] = [:]

    public init(window: TimeInterval = 600, maxEntries: Int = 5_000) {
        self.window = window
        self.maxEntries = maxEntries
    }

    /// The key that makes two observations "the same vehicle here": the source, plus the strongest identifier we have.
    public static func key(source: String, agencyKey: String?, unit: String?, plate: String?, vehicleClass: String) -> String {
        let who = [agencyKey, unit.map { "unit:\($0)" }, plate.map { "plate:\($0)" }]
            .compactMap { $0 }.joined(separator: "|")
        return "\(source)#\(who.isEmpty ? "class:\(vehicleClass)" : who)"
    }

    /// True when this observation should be recorded (and remembers it); false when the same key was recorded
    /// within `window`.
    public mutating func shouldRecord(key: String, now: Date = Date()) -> Bool {
        if let last = lastRecorded[key], now.timeIntervalSince(last) < window { return false }
        lastRecorded[key] = now
        if lastRecorded.count > maxEntries { prune(now: now) }
        return true
    }

    /// Drops expired entries; if still over the cap, drops the oldest so memory stays bounded.
    private mutating func prune(now: Date) {
        lastRecorded = lastRecorded.filter { now.timeIntervalSince($0.value) < window }
        if lastRecorded.count > maxEntries {
            let keep = lastRecorded.sorted { $0.value > $1.value }.prefix(maxEntries / 2)
            lastRecorded = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
    }

    public var trackedCount: Int { lastRecorded.count }
}
