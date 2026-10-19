import Foundation
import PlateKit

/// The nearest named Census place to a camera's recorded position, for list labels and sorting.
/// This is a *nearest-place label*, not a jurisdiction boundary: a highway camera between two towns gets the
/// closer town's name, and a camera near a state line can be labelled with the neighbouring state's town.
/// Provenance: `Gazetteer.citation` (US Census Gazetteer, public domain). Nothing here is sent anywhere.
public struct FeedPlace: Sendable, Equatable, Hashable {
    public var city: String
    public var state: String
    public var distanceKm: Double
    /// "Spokane, WA"
    public var label: String { "\(city), \(state)" }
}

public struct FeedPlaceIndex: Sendable {
    /// Beyond this a label would mislead (open desert, mountain pass); the camera keeps its recorded state only.
    public static let maxDistanceKm = 40.0
    private struct Cell: Hashable { var lat: Int; var lon: Int }
    private let cells: [Cell: [GazetteerPlace]]

    public init(gazetteer: Gazetteer = .shared) {
        var cells: [Cell: [GazetteerPlace]] = [:]
        for p in gazetteer.allPlaces where p.kind != .county && !Self.isStatisticalDivision(p.name) {
            cells[Cell(lat: Int(p.latitude.rounded(.down)), lon: Int(p.longitude.rounded(.down))), default: []].append(p)
        }
        self.cells = cells
    }

    /// Census county divisions ("Reno North CCD") and unorganized territories are survey areas, not names people use.
    static func isStatisticalDivision(_ name: String) -> Bool {
        name.hasSuffix(" CCD") || name.hasSuffix(" UT") || name.contains("Unorganized")
    }

    public func place(latitude: Double, longitude: Double) -> FeedPlace? {
        let c0 = Cell(lat: Int(latitude.rounded(.down)), lon: Int(longitude.rounded(.down)))
        var best: (place: GazetteerPlace, km: Double)?
        // An incorporated place wins over a statistical CDP unless the CDP is clearly closer.
        func score(_ p: GazetteerPlace, _ km: Double) -> Double { p.kind.isGovernment ? km : km + 3 }
        for ring in 0...2 {
            for dLat in -ring...ring {
                for dLon in -ring...ring where max(abs(dLat), abs(dLon)) == ring {
                    for p in cells[Cell(lat: c0.lat + dLat, lon: c0.lon + dLon)] ?? [] {
                        let km = Self.distanceKm(latitude, longitude, p.latitude, p.longitude)
                        if best == nil || score(p, km) < score(best!.place, best!.km) { best = (p, km) }
                    }
                }
            }
            // A hit inside ring r can still be beaten by a closer place in ring r+1 only when it is farther than
            // ring r's guaranteed reach (~69 km·r at the equator, less in longitude); one extra ring covers it.
            if let b = best, b.km < 30 * Double(max(ring, 1)) { break }
        }
        guard let best, best.km <= Self.maxDistanceKm else { return nil }
        return FeedPlace(city: best.place.name, state: best.place.state, distanceKm: best.km)
    }

    public func place(for source: PublicFeedSource) -> FeedPlace? {
        guard let c = Geohash.decodeCenter(source.geohash6) else { return nil }
        return place(latitude: c.latitude, longitude: c.longitude)
    }

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, toRad = Double.pi / 180
        let dLat = (lat2 - lat1) * toRad, dLon = (lon2 - lon1) * toRad
        let a = sin(dLat / 2) * sin(dLat / 2) + cos(lat1 * toRad) * cos(lat2 * toRad) * sin(dLon / 2) * sin(dLon / 2)
        return 2 * r * asin(min(1, sqrt(a)))
    }
}
