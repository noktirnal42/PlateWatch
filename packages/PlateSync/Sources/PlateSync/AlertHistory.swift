import Foundation

/// One watchlist hit the phone alerted on. Stored so alerts can be reviewed after the notification is dismissed.
/// It holds only what the alert itself showed: the watchlisted plate the user typed, the unit, the ~1 km cell and times —
/// never a crop, exact location or anything about a person.
public struct WatchlistAlertRecord: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var alertedAt: Date
    public var capturedAt: Date?
    public var plate: String
    public var unitNumber: String?
    public var geohash6: String?
    public var sightingID: UUID?

    public init(id: UUID = UUID(), alertedAt: Date = Date(), capturedAt: Date? = nil, plate: String,
                unitNumber: String? = nil, geohash6: String? = nil, sightingID: UUID? = nil) {
        self.id = id; self.alertedAt = alertedAt; self.capturedAt = capturedAt; self.plate = plate
        self.unitNumber = unitNumber; self.geohash6 = geohash6; self.sightingID = sightingID
    }
}

/// Bounded, newest-first alert log persisted as JSON in `UserDefaults` (shared by the app and background pushes).
/// A sighting already alerted on is not recorded twice, so a repeated delta pull does not spam the history.
public struct AlertHistory: Sendable, Codable, Equatable {
    public static let capacity = 100
    public private(set) var records: [WatchlistAlertRecord] = []
    public init() {}

    /// Returns false when the sighting was already in the log.
    @discardableResult
    public mutating func record(_ alert: WatchlistAlertRecord) -> Bool {
        if let sid = alert.sightingID, records.contains(where: { $0.sightingID == sid }) { return false }
        records.append(alert)
        // Newest first by alert time (stable for equal times, so later inserts stay on top).
        records = records.enumerated().sorted {
            $0.element.alertedAt != $1.element.alertedAt ? $0.element.alertedAt > $1.element.alertedAt : $0.offset > $1.offset
        }.map(\.element)
        if records.count > Self.capacity { records.removeLast(records.count - Self.capacity) }
        return true
    }

    public mutating func remove(_ id: UUID) { records.removeAll { $0.id == id } }
    public mutating func clear() { records.removeAll() }
}

public enum AlertHistoryStore {
    public static let key = "watchlistAlertHistory"

    public static func load(_ defaults: UserDefaults = .standard) -> AlertHistory {
        guard let data = defaults.data(forKey: key) else { return AlertHistory() }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(AlertHistory.self, from: data)) ?? AlertHistory()
    }

    public static func save(_ history: AlertHistory, _ defaults: UserDefaults = .standard) {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(history) { defaults.set(data, forKey: key) }
    }

    /// Load–modify–save in one step for callers that only append.
    @discardableResult
    public static func append(_ alert: WatchlistAlertRecord, _ defaults: UserDefaults = .standard) -> Bool {
        var history = load(defaults)
        let added = history.record(alert)
        if added { save(history, defaults) }
        return added
    }
}
