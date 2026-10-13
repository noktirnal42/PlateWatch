import Foundation

/// Turns what was read off one vehicle into a structured, cross-referenceable
/// `VehicleIdentity`. The central inference:
///
///     "WALTHAM" (tailgate) + "POLICE" (plate) + "Massachusetts" (plate header)
///         →  Waltham Police Department, MA   (key "US-MA/waltham/police")
///
/// Place names are validated against the Census gazetteer *in the plate's state*, so a
/// partial or misread fragment ("THAM") resolves to real candidates, and genuine
/// ambiguity (Waltham vs Chatham) is reported rather than guessed.
public struct IdentityResolver: Sendable {
    public var gazetteer: Gazetteer

    public init(gazetteer: Gazetteer = .shared) { self.gazetteer = gazetteer }

    /// A rough location (e.g. the sighting's geohash centre) used only to pick between
    /// otherwise-equal places such as Akron, OH and Akron, CO.
    public struct LocationHint: Sendable {
        public var latitude: Double, longitude: Double
        public init(latitude: Double, longitude: Double) { self.latitude = latitude; self.longitude = longitude }
    }

    // MARK: - Entry points

    public func resolve(vehicle: VehicleObservation, location: LocationHint? = nil) -> VehicleIdentity {
        resolve(sceneText: vehicle.sceneText, plates: vehicle.plates, vehicleClass: vehicle.vehicleClass,
                markings: SceneTextHeuristics.parse(vehicle.sceneText), location: location,
                enhancedText: vehicle.enhancedText)
    }

    /// - Parameter enhancedText: lines from the contrast-enhanced pass. They may supply the
    ///   *place* (and state) of an already-fleet vehicle; they are never used to decide
    ///   whether it is a fleet vehicle.
    public func resolve(sceneText: [SceneTextObservation], plates: [PlateObservation],
                        vehicleClass: VehicleClass, markings: FleetMarkings,
                        location: LocationHint? = nil,
                        enhancedText: [SceneTextObservation] = [],
                        userState: String? = nil) -> VehicleIdentity {
        var evidence: [IdentityEvidence] = []
        var consistency: [String] = []

        // ---- Plate ----
        let plate = plates.compactMap(\.best).first { $0.isOfficialPlate } ?? plates.compactMap(\.best).first
        var plateIdentity: PlateIdentity?
        var plateState: String?
        if let plate {
            plateState = USStates.code(fromRegion: plate.issuingRegion)
            plateIdentity = PlateIdentity(registration: plate.text, state: plateState,
                                          stateName: plateState.flatMap(USStates.name(forCode:)),
                                          design: plate.plateDesign, confidence: plate.confidence)
            evidence.append(.init(field: "registration", value: plate.text, source: .plateText,
                                  detail: plate.officialWords.isEmpty ? nil : plate.officialWords.joined(separator: " "),
                                  confidence: plate.confidence))
            if let state = plateState, let name = USStates.name(forCode: state) {
                evidence.append(.init(field: "state", value: state, source: .plateHeader, detail: name, confidence: 0.9))
            }
        }

        // ---- Service (door text first, then the plate's own official words) ----
        var service = markings.serviceClassText
        var serviceSource = IdentityEvidence.Source.doorText
        if service == nil, let plate {
            if plate.officialWords.contains("POLICE") { service = "POLICE"; serviceSource = .plateText }
            else if plate.officialWords.contains("SHERIFF") { service = "SHERIFF"; serviceSource = .plateText }
        }
        if let service {
            evidence.append(.init(field: "service", value: service, source: serviceSource, confidence: 0.85))
        }
        let resolvedClass = Self.vehicleClass(forService: service) ?? vehicleClass

        // ---- Candidate states ----
        let lines = (sceneText + enhancedText).map { TextMatching.key($0.text) }.filter { !$0.isEmpty }
        let textStates = Self.statesNamed(in: lines)
        for s in textStates where s != plateState {   // the plate header already supplied that one
            evidence.append(.init(field: "state", value: s, source: .doorText, detail: USStates.name(forCode: s), confidence: 0.8))
        }
        if let userState {
            evidence.append(.init(field: "state", value: userState, source: .user,
                                  detail: "chosen by the reviewer", confidence: 0.95))
        }
        let searchStates = ([userState, plateState].compactMap { $0 } + textStates).reduce(into: [String]()) {
            if !$0.contains($1) { $0.append($1) }
        }

        // ---- Agency ----
        let anchorState = userState ?? plateState   // a verified state: plate header or the reviewer
        var agency = Self.stateLevelAgency(service: service, markings: markings,
                                           state: userState ?? textStates.first ?? plateState, lines: lines)
        if agency == nil {
            agency = municipalAgency(lines: lines, service: service, resolvedClass: resolvedClass,
                                     searchStates: searchStates, plateState: anchorState,
                                     location: location, evidence: &evidence)
        }
        if agency == nil, let service, let state = plateState ?? textStates.first {
            // Know what and which state, not where: still catalogue it, flagged.
            let stateName = USStates.name(forCode: state) ?? state
            let noun = Self.serviceNoun(service)
            agency = AgencyIdentity(name: "\(stateName) \(noun) (agency not identified)", service: Self.display(service),
                                    vehicleClass: resolvedClass, state: state,
                                    agencyKey: "US-\(state)/unknown/\(Self.slug(service))",
                                    confidence: 0.3, isInferred: true, needsReview: true)
        }

        // ---- Consistency ----
        if let a = agency, let ps = plateState, let s = a.state {
            consistency.append(ps == s ? "Plate state \(ps) matches agency state"
                                       : "Plate issued in \(ps) but agency is in \(s) (out-of-state plate)")
        }
        if let a = agency, let loc = location, let lat = a.latitude, let lon = a.longitude {
            let km = Self.distanceKm(loc.latitude, loc.longitude, lat, lon)
            consistency.append(km < 60 ? "Sighting is \(Int(km)) km from \(a.place ?? "the agency's place")"
                                       : "Sighting is \(Int(km)) km from \(a.place ?? "the agency's place") — unusual")
        }

        // ---- Unit numbers, vehicle ----
        // A unit number is short, has a digit, and is not plate text or a service word.
        let registration = plateIdentity?.registration ?? ""
        func plausibleUnit(_ u: String) -> Bool {
            let k = TextMatching.key(u)
            return u.count <= 6 && u.contains(where: \.isNumber)
                && !Plate.officialPlateWords.contains(where: { k.contains($0) || u.uppercased().contains($0) })
                && !u.uppercased().contains(where: { _ in false })
                && (registration.isEmpty || !u.uppercased().contains(registration) )
        }
        var units: [String] = []
        if let u = markings.unitNumber, plausibleUnit(u) { units.append(u) }
        for line in sceneText {
            let t = line.text.trimmingCharacters(in: .whitespaces)
            if t.count >= 2, t.count <= 5, t.allSatisfy(\.isNumber), t != "911", !units.contains(t) { units.append(t) }
        }
        units = Array(units.prefix(3))
        for u in units { evidence.append(.init(field: "unit", value: u, source: .doorText, confidence: 0.6)) }

        let descriptor = Self.describeVehicle(lines: lines)
        if let make = descriptor.make { evidence.append(.init(field: "make", value: make, source: .doorText, confidence: 0.7)) }
        if let model = descriptor.model { evidence.append(.init(field: "model", value: model, source: .doorText, confidence: 0.6)) }

        return VehicleIdentity(plate: plateIdentity, agency: agency, unitNumbers: units, vehicle: descriptor,
                               evidence: evidence, consistency: consistency)
    }

    // MARK: - Municipal / county agencies

    private static let stopWords: Set<String> = [
        "POLICE", "SHERIFF", "SHERIFFS", "FIRE", "DEPT", "DEPARTMENT", "RESCUE", "EMS", "AMBULANCE", "PARAMEDIC",
        "STATE", "TROOPER", "HIGHWAY", "PATROL", "UNIT", "CITY", "TOWN", "OF", "THE", "COUNTY", "SERVICE",
        "PUBLIC", "WORKS", "TRANSIT", "METRO", "OFFICIAL", "INTERCEPTOR", "HYBRID", "AWD", "EMERGENCY", "CALL",
        "SAFETY", "DIAL", "SCHOOL", "DISTRICT", "BUS", "ROUTE", "PARK", "RANGER", "MARSHAL", "ENGINE", "LADDER",
        "TRUCK", "SQUAD", "BATTALION", "UNITED", "STATES", "US", "FORD", "DODGE", "CHEVROLET", "CHEVY", "TOYOTA",
        "HONDA", "NISSAN", "JEEP", "RAM", "GMC", "TESLA", "BMW", "EXPLORER", "TAHOE", "CHARGER", "DURANGO",
        "SILVERADO", "SUBURBAN", "UTILITY", "PURSUIT", "FOR", "ONLY", "NEW", "AND", "AVE", "ST", "STREET",
    ]

    private func municipalAgency(lines: [String], service: String?, resolvedClass: VehicleClass,
                                 searchStates: [String], plateState: String?, location: LocationHint?,
                                 evidence: inout [IdentityEvidence]) -> AgencyIdentity? {
        guard let service else { return nil }
        let wantsCounty = Self.isCountyService(service) || lines.contains { $0.split(separator: " ").contains("COUNTY") }
        let stateNames = Set(USStates.all.map { TextMatching.key($0.name) })

        // n-grams (1–3 tokens) of tokens that are not generic words, per line.
        var grams: [String] = []
        for line in lines {
            let tokens = line.split(separator: " ").map(String.init)
            for i in tokens.indices {
                for n in 1...3 where i + n <= tokens.count {
                    let slice = tokens[i..<(i + n)]
                    if slice.contains(where: { Self.stopWords.contains($0) }) { continue }
                    let g = slice.joined(separator: " ")
                    if (stateNames.contains(g) && !wantsCounty) || g.count < 4 { continue }
                    if !grams.contains(g) { grams.append(g) }
                }
            }
        }

        struct Scored { var match: PlaceMatch; var score: Double }
        var scored: [Scored] = []
        let states: [String?] = searchStates.isEmpty ? [nil] : searchStates.map { Optional($0) }
        for gram in grams {
            for st in states {
                for m in gazetteer.resolve(gram, state: st) {
                    if wantsCounty ? m.place.kind != .county : m.place.kind == .county { continue }
                    var s = [0.0, 0.5, 0.78, 1.0][m.strength.rawValue]
                    if m.place.state == plateState { s += 0.1 }
                    s += min(0.1, Double(gram.count) / 100)           // longer text, stronger
                    scored.append(Scored(match: m, score: s))
                }
            }
        }
        guard !scored.isEmpty else { return nil }
        scored.sort { $0.score > $1.score }

        // A place supported by several fragments ("ALTHAM" and "THAM") beats one only a single fragment
        // fits ("THAM" also fits Wrentham). Aggregate per place: best score per distinct text, summed.
        var byPlace: [String: (scored: Scored, total: Double, texts: Set<String>)] = [:]
        for s in scored {
            let k = "\(s.match.place.state)|\(s.match.place.name)|\(s.match.place.kind.rawValue)"
            if var cur = byPlace[k] {
                if cur.texts.insert(s.match.matchedText).inserted { cur.total += s.score }
                if s.score > cur.scored.score { cur.scored = s }
                byPlace[k] = cur
            } else { byPlace[k] = (s, s.score, [s.match.matchedText]) }
        }
        let ranked = byPlace.values.sorted { $0.total > $1.total }
        let leaderTotal = ranked[0].total
        // The leader stands alone when it is clearly ahead of the runner-up; otherwise the near-ties are ambiguous.
        var top: [Scored] = ranked.filter { leaderTotal - $0.total < 0.3 }.map { $0.scored }
        var resolvedByLocation = false
        if top.count > 1, let loc = location {
            let ordered = top.sorted {
                Self.distanceKm(loc.latitude, loc.longitude, $0.match.place.latitude, $0.match.place.longitude)
                < Self.distanceKm(loc.latitude, loc.longitude, $1.match.place.latitude, $1.match.place.longitude)
            }
            let d0 = Self.distanceKm(loc.latitude, loc.longitude, ordered[0].match.place.latitude, ordered[0].match.place.longitude)
            let d1 = Self.distanceKm(loc.latitude, loc.longitude, ordered[1].match.place.latitude, ordered[1].match.place.longitude)
            // Decisive when the sighting is inside one candidate (a town is ~10 km across) and the
            // runner-up is both far (> 20 km) and well over 3× as far.
            if d0 < 10 && d1 > 20 && d1 > 3 * d0 { top = [ordered[0]]; resolvedByLocation = true }
        }
        // Unique places among the top group, most prominent (largest land area) first.
        var seen = Set<String>(); var unique: [Scored] = []
        for t in top.sorted(by: { $0.match.place.areaSqMi > $1.match.place.areaSqMi })
        where seen.insert("\(t.match.place.state)|\(t.match.place.name)").inserted { unique.append(t) }
        guard let chosen = unique.first else { return nil }
        let ambiguous = unique.count > 1
        let place = chosen.match.place
        let strength = chosen.match.strength

        var confidence: Double
        switch strength {
        case .exact: confidence = place.state == plateState ? 0.93 : 0.78
        case .fuzzy: confidence = place.state == plateState ? 0.8 : 0.65
        case .fragment: confidence = place.state == plateState ? 0.7 : 0.5
        }
        if ambiguous { confidence = min(confidence, 0.45) }
        if resolvedByLocation { confidence = max(confidence, 0.75) }
        let needsReview = ambiguous || strength == .fragment && !(place.state == plateState)
            || (resolvedByLocation && strength == .fragment) || confidence < 0.6

        let others = unique.dropFirst().prefix(5).map { "\($0.match.place.name), \($0.match.place.state)" }
        let alternatives = ambiguous ? ["\(place.name), \(place.state)"] + others : []
        evidence.append(.init(field: "place", value: place.name, source: .gazetteer,
                              detail: "\(chosen.match.matchedText) → \(place.name), \(place.state) (\(strength))"
                                      + (ambiguous ? "; \(unique.count) candidates" : ""),
                              confidence: confidence))

        // Same name in several states, nothing says which: do not pick one. The place is known,
        // the state is not, and the candidates are listed for a person (or a location) to settle.
        let sameNameAcrossStates = ambiguous && Set(unique.map { $0.match.place.name }).count == 1
        // Different names from a partial reading ("THAM"): even the place is unclear.
        let placeUnclear = ambiguous && !sameNameAcrossStates

        let displayPlace: String? = placeUnclear ? nil : place.name
        let displayState: String? = sameNameAcrossStates || placeUnclear
            ? (Set(unique.map { $0.match.place.state }).count == 1 ? place.state : nil) : place.state
        let nameBase = place.kind == .county ? "\(place.name) County" : place.name
        let name: String
        if placeUnclear { name = "\(Self.serviceNoun(service, county: false)) (place unclear)" }
        else { name = "\(nameBase) \(Self.serviceNoun(service, county: place.kind == .county))"
                + (displayState == nil ? " (state unknown)" : "") }
        let key = "US-\(displayState ?? "??")/\(displayPlace.map(Self.slug) ?? "unknown")/\(Self.slug(service))"
        return AgencyIdentity(
            name: name, service: Self.display(service), vehicleClass: resolvedClass,
            place: displayPlace, placeKind: placeUnclear ? nil : place.kind.rawValue, state: displayState,
            agencyKey: key,
            latitude: displayState == nil || placeUnclear ? nil : place.latitude,
            longitude: displayState == nil || placeUnclear ? nil : place.longitude,
            geoid: displayState == nil || placeUnclear ? nil : place.geoid,
            confidence: confidence, isInferred: true, needsReview: needsReview,
            alternatives: alternatives, citation: Gazetteer.citation)
    }

    // MARK: - State-level agencies (State Police, Highway Patrol)

    private static func stateLevelAgency(service: String?, markings: FleetMarkings, state: String?,
                                          lines: [String]) -> AgencyIdentity? {
        guard let service, let state, let stateName = USStates.name(forCode: state) else { return nil }
        let joined = " " + lines.joined(separator: " ") + " "
        let isState = ["STATE TROOPER", "TROOPER", "HIGHWAY PATROL"].contains(service)
            || (service == "POLICE" && joined.contains(" STATE POLICE "))
        guard isState else { return nil }
        let patrol = service == "HIGHWAY PATROL" || joined.contains(" HIGHWAY PATROL ")
        let label = patrol ? "Highway Patrol" : (joined.contains(" TROOPERS ") || service == "STATE TROOPER" && !joined.contains(" STATE POLICE ")
                                                  ? "State Patrol" : "State Police")
        // Missouri's is "State Highway Patrol", Michigan's "State Police" — keep the verbatim form when read.
        let verbatim = lines.first { $0.contains(TextMatching.key(stateName)) && ($0.contains("PATROL") || $0.contains("STATE POLICE")) }
        let name = verbatim.map { $0.split(separator: " ").map { $0.capitalized }.joined(separator: " ") }
            ?? "\(stateName) \(label)"
        return AgencyIdentity(name: name, service: label, vehicleClass: .highway, state: state,
                              agencyKey: "US-\(state)/state/\(slug(label))",
                              confidence: 0.85, isInferred: verbatim == nil, needsReview: false)
    }

    // MARK: - Vocabulary

    static func serviceNoun(_ service: String, county: Bool = false) -> String {
        switch service {
        case "POLICE", "MARSHAL": return "Police Department"
        case "SHERIFF": return county ? "Sheriff's Office" : "Sheriff's Office"
        case "FIRE", "RESCUE": return "Fire Department"
        case "EMS", "AMBULANCE", "PARAMEDIC": return "EMS"
        case "PUBLIC WORKS", "SANITATION": return "Department of Public Works"
        case "TRANSIT", "METRO": return "Transit"
        case "PARK RANGER": return "Park Rangers"
        case "SCHOOL DISTRICT", "UNIFIED SCHOOL DISTRICT", "SCHOOL BUS": return "School District"
        default: return service.capitalized
        }
    }

    static func display(_ service: String) -> String { service.capitalized }

    static func isCountyService(_ service: String) -> Bool { service == "SHERIFF" }

    static func vehicleClass(forService service: String?) -> VehicleClass? {
        switch service {
        case "POLICE", "SHERIFF", "MARSHAL": return .patrol
        case "STATE TROOPER", "TROOPER", "HIGHWAY PATROL": return .highway
        case "FIRE", "RESCUE": return .fireEngine
        case "EMS", "AMBULANCE", "PARAMEDIC": return .ambulance
        case "PUBLIC WORKS", "SANITATION": return .publicWorks
        case "TRANSIT", "METRO": return .transit
        case "PARK RANGER": return .parkRanger
        case "SCHOOL BUS", "SCHOOL DISTRICT", "UNIFIED SCHOOL DISTRICT": return .schoolBus
        case "POSTAL SERVICE", "USPS": return .federal
        default: return nil
        }
    }

    static func slug(_ s: String) -> String {
        TextMatching.key(s).lowercased().replacingOccurrences(of: " ", with: "-")
    }

    /// State names (as USPS codes) that appear as whole words in any line.
    static func statesNamed(in lines: [String]) -> [String] {
        var out: [String] = []
        for (code, name) in USStates.all {
            let key = TextMatching.key(name)
            for line in lines where (" " + line + " ").contains(" " + key + " ") {
                if !out.contains(code) { out.append(code) }
            }
        }
        // "WASHINGTON" in "WASHINGTON DC"-style text is ignored when DC is present.
        return out
    }

    // MARK: - Vehicle make / model from badges

    private static let makes: [String: String] = [
        "FORD": "Ford", "CHEVROLET": "Chevrolet", "CHEVY": "Chevrolet", "DODGE": "Dodge", "TOYOTA": "Toyota",
        "HONDA": "Honda", "NISSAN": "Nissan", "JEEP": "Jeep", "RAM": "Ram", "GMC": "GMC", "TESLA": "Tesla",
        "BMW": "BMW", "HARLEY": "Harley-Davidson", "FREIGHTLINER": "Freightliner", "PIERCE": "Pierce",
        "FERRARA": "Ferrara", "KENWORTH": "Kenworth", "MACK": "Mack", "INTERNATIONAL": "International",
    ]
    private static let models: [(token: String, name: String)] = [
        ("INTERCEPTOR", "Police Interceptor"), ("EXPLORER", "Explorer"), ("TAHOE", "Tahoe"),
        ("CHARGER", "Charger"), ("DURANGO", "Durango"), ("SILVERADO", "Silverado"), ("SUBURBAN", "Suburban"),
        ("EXPEDITION", "Expedition"), ("TRANSIT", "Transit"), ("SPRINTER", "Sprinter"), ("CROWN VICTORIA", "Crown Victoria"),
        ("IMPALA", "Impala"), ("CAMARO", "Camaro"), ("MUSTANG", "Mustang"), ("F150", "F-150"), ("F250", "F-250"),
    ]
    private static let traits: [(token: String, name: String)] = [
        ("HYBRID", "Hybrid"), ("AWD", "AWD"), ("4X4", "4x4"), ("ECOBOOST", "EcoBoost"), ("PPV", "PPV"),
        ("PURSUIT", "Pursuit"), ("UTILITY", "Utility"),
    ]

    static func describeVehicle(lines: [String]) -> VehicleDescriptor {
        var d = VehicleDescriptor()
        let tokens = lines.flatMap { $0.split(separator: " ").map(String.init) }
        for t in tokens {
            if d.make == nil, let m = makes[t] { d.make = m }
            if d.make == nil, t.count >= 5, let m = makes.first(where: {
                $0.key.count >= 5 && TextMatching.withinOneEdit(Array($0.key), Array(t)) }) { d.make = m.value }
        }
        let joined = " " + lines.joined(separator: " ") + " "
        for m in models where joined.contains(" \(m.token) ")
            || (m.token.count >= 6 && tokens.contains { TextMatching.withinOneEdit(Array(m.token), Array($0)) }) {
            if d.model == nil { d.model = m.name }
        }
        for t in traits where tokens.contains(t.token)
            || (t.token.count >= 5 && tokens.contains { TextMatching.withinOneEdit(Array(t.token), Array($0)) }) {
            if !d.traits.contains(t.name) { d.traits.append(t.name) }
        }
        return d
    }

    // MARK: - Geometry

    static func distanceKm(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
        let r = 6371.0, p = Double.pi / 180
        let a = sin((lat2 - lat1) * p / 2), b = sin((lon2 - lon1) * p / 2)
        let h = a * a + cos(lat1 * p) * cos(lat2 * p) * b * b
        return 2 * r * asin(min(1, sqrt(h)))
    }
}
