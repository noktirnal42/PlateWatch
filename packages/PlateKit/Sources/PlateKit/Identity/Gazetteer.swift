import Foundation

/// A US place, town or county from the Census Gazetteer (public domain).
public struct GazetteerPlace: Sendable, Hashable, Codable {
    public var state: String        // USPS code, "MA"
    public var name: String         // "Waltham"
    public var kind: Kind
    public var latitude: Double
    public var longitude: Double
    public var geoid: String
    /// Land area in square miles — only a crude prominence prior for ranking same-name places.
    public var areaSqMi: Double

    public enum Kind: String, Sendable, Codable {
        case city, town, village, borough, township, county, cdp, place
        /// Incorporated, runs its own services. CDPs are statistical areas, not governments.
        public var isGovernment: Bool { self != .cdp }
    }
}

/// How a piece of OCR text matched a gazetteer place.
public struct PlaceMatch: Sendable, Hashable {
    public enum Strength: Int, Sendable, Comparable {
        case fragment = 1   // text is a piece of the name ("THAM" ⊂ "WALTHAM")
        case fuzzy = 2      // one OCR error away
        case exact = 3
        public static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }
    public var place: GazetteerPlace
    public var strength: Strength
    /// The OCR text that produced the match.
    public var matchedText: String
}

/// Canonical place names by state, used to validate OCR'd place names against real
/// places in the plate's state. Built from the US Census Gazetteer (public domain):
/// `scripts/build-gazetteer.py`. Reading "THAM" on a Massachusetts vehicle yields
/// Waltham *and* Chatham, so ambiguity is reported, never silently resolved.
public struct Gazetteer: Sendable {
    private let places: [GazetteerPlace]
    private let byState: [String: [Int]]
    private let byKey: [String: [Int]]
    private let keys: [String]

    public init(tsv: String) {
        var places: [GazetteerPlace] = []
        for line in tsv.split(separator: "\n", omittingEmptySubsequences: true) {
            let f = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard f.count >= 6, let lat = Double(f[3]), let lon = Double(f[4]) else { continue }
            places.append(GazetteerPlace(state: String(f[0]), name: String(f[1]),
                                         kind: GazetteerPlace.Kind(rawValue: String(f[2])) ?? .place,
                                         latitude: lat, longitude: lon, geoid: String(f[5]),
                                         areaSqMi: f.count > 6 ? Double(f[6]) ?? 0 : 0))
        }
        var byState: [String: [Int]] = [:]
        var byKey: [String: [Int]] = [:]
        var keys: [String] = []
        for (i, p) in places.enumerated() {
            let k = TextMatching.key(p.name)
            keys.append(k)
            byState[p.state, default: []].append(i)
            byKey[k, default: []].append(i)
        }
        self.places = places; self.byState = byState; self.byKey = byKey; self.keys = keys
    }

    public var count: Int { places.count }

    /// The bundled Census gazetteer (loaded once).
    public static let shared: Gazetteer = {
        guard let url = Bundle.module.url(forResource: "gazetteer", withExtension: "tsv"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return Gazetteer(tsv: "") }
        return Gazetteer(tsv: text)
    }()

    /// Provenance for every place name this gazetteer canonicalises.
    public static let citation = SourceCitation(
        sourceType: .censusGazetteer,
        url: URL(string: "https://www2.census.gov/geo/docs/maps-data/data/gazetteer/2023_Gazetteer/"),
        retrievedAt: Date(timeIntervalSince1970: 1_791_900_000)) // 2026-10-13

    public func places(inState state: String) -> [GazetteerPlace] {
        (byState[state.uppercased()] ?? []).map { places[$0] }
    }

    /// Match OCR text to places. With a `state`, exact, one-edit and fragment matches
    /// are considered; without one only exact matches are returned (a fragment across
    /// 59k places is meaningless). Government places outrank CDPs of the same name.
    public func resolve(_ rawText: String, state: String?) -> [PlaceMatch] {
        let key = TextMatching.key(rawText)
        guard key.count >= 3 else { return [] }
        var found: [PlaceMatch] = []
        let candidates: [Int] = state.flatMap { byState[$0.uppercased()] } ?? Array(places.indices)

        if let exact = byKey[key] {
            for i in exact where state == nil || places[i].state == state!.uppercased() {
                found.append(PlaceMatch(place: places[i], strength: .exact, matchedText: rawText))
            }
        }
        if state != nil {
            let target = Array(key)
            if key.count >= 6 {
                for i in candidates where keys[i] != key
                    && TextMatching.withinOneEdit(Array(keys[i]), target) {
                    found.append(PlaceMatch(place: places[i], strength: .fuzzy, matchedText: rawText))
                }
            }
            if key.count >= 4 {
                for i in candidates where keys[i].count > key.count && keys[i].contains(key) {
                    found.append(PlaceMatch(place: places[i], strength: .fragment, matchedText: rawText))
                }
            }
        }
        return Self.deduplicated(found)
    }

    /// One entry per (state, name): prefer an incorporated government over a CDP, and the
    /// stronger match over the weaker.
    private static func deduplicated(_ matches: [PlaceMatch]) -> [PlaceMatch] {
        var best: [String: PlaceMatch] = [:]
        for m in matches {
            let k = "\(m.place.state)|\(TextMatching.key(m.place.name))"
            if let cur = best[k] {
                if (m.strength, m.place.kind.isGovernment ? 1 : 0) > (cur.strength, cur.place.kind.isGovernment ? 1 : 0) {
                    best[k] = m
                }
            } else { best[k] = m }
        }
        return best.values.sorted {
            ($0.strength.rawValue, $1.place.name) > ($1.strength.rawValue, $0.place.name)
        }
    }
}
