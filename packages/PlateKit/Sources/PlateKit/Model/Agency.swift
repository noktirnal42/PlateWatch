import Foundation

public enum AgencyLevel: String, Sendable, Codable, CaseIterable {
    case municipal, county, state, federal, tribal, specialDistrict
}

/// A government body that operates taxpayer-funded vehicles.
public struct Agency: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    public var name: String
    public var shortName: String?
    public var level: AgencyLevel
    /// Coarse jurisdiction geometry (GeoJSON). Optional; used for heatmaps.
    public var jurisdictionGeoJSON: String?
    public var parentAgencyID: UUID?
    public var publicContactURL: URL?

    public init(id: UUID = UUID(),
                name: String,
                shortName: String? = nil,
                level: AgencyLevel,
                jurisdictionGeoJSON: String? = nil,
                parentAgencyID: UUID? = nil,
                publicContactURL: URL? = nil) {
        self.id = id
        self.name = name
        self.shortName = shortName
        self.level = level
        self.jurisdictionGeoJSON = jurisdictionGeoJSON
        self.parentAgencyID = parentAgencyID
        self.publicContactURL = publicContactURL
    }
}

/// A roster/assignment link between a fleet unit number, a vehicle, and
/// (only when publicly documented) an officer name.
public struct UnitAssignment: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    public var agencyID: UUID
    public var unitNumber: String
    public var vehicleID: UUID?
    /// Populated only from cited public rosters — never from DMV/broker data.
    public var subjectName: String?
    public var role: Role
    public var effectiveFrom: Date?
    public var effectiveTo: Date?
    public var confidence: LinkConfidence
    public var provenance: [SourceCitation]

    public enum Role: String, Sendable, Codable {
        case patrol, k9, supervisor, command, support, other
    }

    public enum LinkConfidence: String, Sendable, Codable, Comparable {
        case inferred, singleSource, officialRoster, communityVerified

        public static func < (lhs: Self, rhs: Self) -> Bool {
            let order: [Self] = [.inferred, .singleSource, .communityVerified, .officialRoster]
            return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
        }
    }

    public init(id: UUID = UUID(),
                agencyID: UUID,
                unitNumber: String,
                vehicleID: UUID? = nil,
                subjectName: String? = nil,
                role: Role = .other,
                effectiveFrom: Date? = nil,
                effectiveTo: Date? = nil,
                confidence: LinkConfidence = .inferred,
                provenance: [SourceCitation] = []) {
        self.id = id
        self.agencyID = agencyID
        self.unitNumber = unitNumber
        self.vehicleID = vehicleID
        self.subjectName = subjectName
        self.role = role
        self.effectiveFrom = effectiveFrom
        self.effectiveTo = effectiveTo
        self.confidence = confidence
        self.provenance = provenance
    }
}
