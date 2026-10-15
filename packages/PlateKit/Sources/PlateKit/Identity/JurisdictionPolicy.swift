import Foundation

/// Where plate recognition may run. Some states regulate *use of an automated licence-plate-recognition system by
/// any person* (Maine, 29-A MRSA §2117-A; New Hampshire RSA 261:75-b limits ALPR to law enforcement). Whether OCR of
/// plates from a third-party public camera feed is such "use" is an open question for counsel
/// (docs/FEED-LEGAL-RESEARCH.md), so the Hub fails closed: **no plate recognition runs** (not just "results hidden")
/// for a source in, near, or of unknown location relative to a restricted state. Fleet detection from door lettering and
/// vehicle appearance is unaffected.
///
/// Not legal advice; the lists change as statutes do — review before relying on them.
public enum JurisdictionPolicy {

    /// Statute text read (VERIFIED in the research): plate recognition disabled by default.
    public static let platesRestricted: Set<String> = ["ME", "NH"]

    /// Reported by a secondary source (NCSL) and pending counsel: also disabled by default.
    public static let platesPendingCounsel: Set<String> = ["AR", "ID", "KY", "CT"]

    public static var platesDisabledByDefault: Set<String> { platesRestricted.union(platesPendingCounsel) }

    /// Radius around the camera in which any restricted state blocks plate reading. A place just across a state
    /// line must not slip through because the nearest census place is on the other side.
    public static let borderMarginKm: Double = 30

    /// May plate recognition run for a source at `location`? Unknown location → no (fail closed).
    public static func mayReadPlates(near location: IdentityResolver.LocationHint?,
                                     gazetteer: Gazetteer = .shared,
                                     disabledStates: Set<String> = platesDisabledByDefault) -> Bool {
        guard let location else { return false }
        let states = gazetteer.states(near: location.latitude, longitude: location.longitude, withinKm: borderMarginKm)
        guard !states.isEmpty else { return false }          // nothing nearby in the gazetteer: do not guess
        return states.isDisjoint(with: disabledStates)
    }
}

public extension Gazetteer {
    /// Every state that has a catalogued place within `km` of the point.
    func states(near latitude: Double, longitude: Double, withinKm km: Double) -> Set<String> {
        // Cheap bounding box first (1° latitude ≈ 111 km), then great-circle distance.
        let dLat = km / 111.0
        let dLon = km / max(20.0, 111.0 * cos(latitude * .pi / 180))
        var found = Set<String>()
        for place in allPlaces
        where abs(place.latitude - latitude) <= dLat && abs(place.longitude - longitude) <= dLon {
            if Self.distanceKm(latitude, longitude, place.latitude, place.longitude) <= km { found.insert(place.state) }
        }
        return found
    }

    private static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, p = Double.pi / 180
        let a = sin((lat2 - lat1) * p / 2) * sin((lat2 - lat1) * p / 2)
            + cos(lat1 * p) * cos(lat2 * p) * sin((lon2 - lon1) * p / 2) * sin((lon2 - lon1) * p / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}

/// Thread-safe "may this app read plates right now?" switch for apps whose location changes while frames stream
/// (the handheld iPhone app). Fails closed: until a location has been supplied, or when the location is cleared
/// (e.g. a photo import without GPS), plate reading is off. The gazetteer lookup is cached per ~1 km geohash cell.
public final class PlateReadingGate: @unchecked Sendable {
    private let lock = NSLock()
    private let disabledStates: Set<String>
    private var cellKey: String?
    private var cellAllowed = false

    public init(disabledStates: Set<String> = JurisdictionPolicy.platesDisabledByDefault) {
        self.disabledStates = disabledStates
    }

    /// Whether plate recognition may run for the most recently supplied location.
    public var allowed: Bool { lock.lock(); defer { lock.unlock() }; return cellAllowed }

    /// Updates the location the gate decides on. `nil` (unknown) closes the gate.
    public func update(latitude: Double?, longitude: Double?) {
        guard let latitude, let longitude else { return set(key: nil, allowed: false) }
        let key = Geohash.encode(latitude: latitude, longitude: longitude, precision: 6)
        lock.lock()
        let unchanged = key == cellKey
        lock.unlock()
        if unchanged { return }
        let allowed = JurisdictionPolicy.mayReadPlates(near: .init(latitude: latitude, longitude: longitude),
                                                       disabledStates: disabledStates)
        set(key: key, allowed: allowed)
    }

    private func set(key: String?, allowed: Bool) {
        lock.lock(); defer { lock.unlock() }
        cellKey = key
        cellAllowed = allowed
    }
}
