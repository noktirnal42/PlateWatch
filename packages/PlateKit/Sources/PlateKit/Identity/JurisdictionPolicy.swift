import Foundation

/// Where plate recognition may run. Some states regulate *use of an automated licence-plate-recognition system by
/// any person* (Maine, 29-A MRSA §2117-A; New Hampshire RSA 261:75-b limits ALPR to law enforcement).
///
/// **Owner-reported counsel view (2026-10-15):** neither OCR of plates from third-party public camera feeds nor
/// handheld use is ALPR "use" under those statutes. On that basis the default is **no restricted states**
/// (`platesDisabledByDefault` is empty). This is a relayed position — no written opinion is in the repo — so the
/// state lists below are kept as data and `platesConservativeStates` re-enables the old behaviour in one line
/// (`PlateReadingGate(disabledStates:)` / `mayReadPlates(disabledStates:)`). The gate still fails closed when the
/// location is unknown or outside the catalogued US places: counsel's view was about US statutes, so nothing
/// supports reading plates where the jurisdiction cannot be identified. Fleet detection from door lettering and
/// vehicle appearance is unaffected either way. See docs/PLATE-READING-JURISDICTIONS.md.
///
/// Not legal advice; the lists change as statutes do — review before relying on them.
public enum JurisdictionPolicy {

    /// Statute text read (VERIFIED in the research). Reference data; not enforced by default (see above).
    public static let platesRestricted: Set<String> = ["ME", "NH"]

    /// Reported by a secondary source (NCSL) and pending counsel. Reference data; not enforced by default.
    public static let platesPendingCounsel: Set<String> = ["AR", "ID", "KY", "CT"]

    /// The previous default: every state above. Pass as `disabledStates` to restore the conservative gate.
    public static var platesConservativeStates: Set<String> { platesRestricted.union(platesPendingCounsel) }

    /// States where plate recognition is disabled by default. Empty per the owner-reported counsel view.
    public static var platesDisabledByDefault: Set<String> { [] }

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
