import Foundation

/// One fact in a vehicle's identity, with where it came from. Provenance is the
/// point: every catalogued value can be traced to a piece of evidence, so a
/// moderator (or a FOIA request) can check it.
public struct IdentityEvidence: Sendable, Codable, Hashable {
    public enum Source: String, Sendable, Codable {
        case doorText        // text painted on the vehicle
        case plateText       // registration read from the plate
        case plateHeader     // state name printed on the plate
        case classifier      // image classifier cue (police_car, firetruck…)
        case gazetteer       // canonical place name from the Census gazetteer
        case inference       // combined from other evidence
        case user            // chosen by the person reviewing (e.g. "which Atlanta?")
    }
    public var field: String          // "place", "service", "state", "registration", "unit", "make"…
    public var value: String
    public var source: Source
    /// The raw text it was derived from, when there was any ("THAM", "POLICE D756").
    public var detail: String?
    public var confidence: Double

    public init(field: String, value: String, source: Source, detail: String? = nil, confidence: Double) {
        self.field = field; self.value = value; self.source = source
        self.detail = detail; self.confidence = confidence
    }
}

/// Who operates the vehicle, resolved from what is painted on it plus where it is registered.
public struct AgencyIdentity: Sendable, Codable, Hashable {
    /// Display name: "Waltham Police Department".
    public var name: String
    /// What it does: "Police", "Fire", "Sheriff", "EMS", "Public Works"…
    public var service: String?
    public var vehicleClass: VehicleClass
    /// Town / city / county the agency serves, canonical ("Waltham").
    public var place: String?
    public var placeKind: String?
    /// USPS state code ("MA").
    public var state: String?
    /// Stable cross-reference key, e.g. "US-MA/waltham/police". Joins to fleet rosters,
    /// FOIA targets, open-data feeds and the server's agency table.
    public var agencyKey: String
    /// Centroid of the place — lets a sighting's GPS bucket sanity-check the reading.
    public var latitude: Double?
    public var longitude: Double?
    public var geoid: String?
    public var confidence: Double
    /// True when the name was assembled from several pieces of evidence rather than read verbatim.
    public var isInferred: Bool
    /// A person should look before this is trusted (ambiguous place, partial reading…).
    public var needsReview: Bool
    /// Other places the evidence fits ("Chatham, MA") when the match is ambiguous.
    public var alternatives: [String]
    /// Set whenever a name was canonicalised through the gazetteer (AGENTS.md: no unsourced enrichment).
    public var citation: SourceCitation?

    public init(name: String, service: String?, vehicleClass: VehicleClass, place: String? = nil,
                placeKind: String? = nil, state: String? = nil, agencyKey: String,
                latitude: Double? = nil, longitude: Double? = nil, geoid: String? = nil,
                confidence: Double, isInferred: Bool, needsReview: Bool,
                alternatives: [String] = [], citation: SourceCitation? = nil) {
        self.name = name; self.service = service; self.vehicleClass = vehicleClass
        self.place = place; self.placeKind = placeKind; self.state = state; self.agencyKey = agencyKey
        self.latitude = latitude; self.longitude = longitude; self.geoid = geoid
        self.confidence = confidence; self.isInferred = isInferred; self.needsReview = needsReview
        self.alternatives = alternatives; self.citation = citation
    }
}

/// The plate half of the identity: the registration and where it was issued.
public struct PlateIdentity: Sendable, Codable, Hashable {
    public var registration: String
    /// USPS state code ("MA") when the plate header was read.
    public var state: String?
    public var stateName: String?
    /// "government-official" for POLICE/OFFICIAL plates, nil for ordinary plates.
    public var design: String?
    public var confidence: Double

    public init(registration: String, state: String? = nil, stateName: String? = nil,
                design: String? = nil, confidence: Double) {
        self.registration = registration; self.state = state; self.stateName = stateName
        self.design = design; self.confidence = confidence
    }
}

/// What the vehicle itself is, as far as badges and lettering say.
public struct VehicleDescriptor: Sendable, Codable, Hashable {
    public var make: String?          // "Ford"
    public var model: String?         // "Police Interceptor Utility"
    public var traits: [String]       // ["Hybrid", "AWD"]
    public init(make: String? = nil, model: String? = nil, traits: [String] = []) {
        self.make = make; self.model = model; self.traits = traits
    }
    public var isEmpty: Bool { make == nil && model == nil && traits.isEmpty }
}

/// Everything relevant that can be read off one vehicle, structured for cross-referencing:
/// the registration, where it was issued, the operating agency (verbatim or inferred), unit
/// numbers, and what kind of vehicle it is — each with its evidence.
///
/// This is a *vehicle and agency* record. It never contains anything about a person.
public struct VehicleIdentity: Sendable, Codable, Hashable {
    public var plate: PlateIdentity?
    public var agency: AgencyIdentity?
    public var unitNumbers: [String]
    public var vehicle: VehicleDescriptor
    public var evidence: [IdentityEvidence]
    /// Cross-checks that passed or failed ("plate state matches agency state").
    public var consistency: [String]

    public init(plate: PlateIdentity? = nil, agency: AgencyIdentity? = nil, unitNumbers: [String] = [],
                vehicle: VehicleDescriptor = .init(), evidence: [IdentityEvidence] = [],
                consistency: [String] = []) {
        self.plate = plate; self.agency = agency; self.unitNumbers = unitNumbers
        self.vehicle = vehicle; self.evidence = evidence; self.consistency = consistency
    }

    public var isEmpty: Bool {
        plate == nil && agency == nil && unitNumbers.isEmpty && vehicle.isEmpty
    }
}

public extension VehicleIdentity {
    /// The same identity with the plate registration removed everywhere it appears (the plate
    /// itself and the evidence trail). Used when a sighting is not yet allowed to carry a plate
    /// (LEGAL-ETHICS Rule 1: plates persist only once fleet-confirmed). The jurisdiction ("MA") and
    /// the agency are organisation-level facts and are kept.
    func redactingRegistration() -> VehicleIdentity {
        var copy = self
        if let plate = copy.plate {
            copy.plate = PlateIdentity(registration: "", state: plate.state, stateName: plate.stateName,
                                       design: plate.design, confidence: plate.confidence)
        }
        copy.evidence = copy.evidence.filter { $0.field != "registration" }
        return copy
    }
}
