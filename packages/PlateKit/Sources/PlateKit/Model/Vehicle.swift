import Foundation

/// Broad class of taxpayer-funded vehicle. `privateVehicle` exists so the
/// redaction gate has an explicit negative classification.
public enum VehicleClass: String, Sendable, Codable, CaseIterable {
    case patrol, fireEngine, ambulance, publicWorks, transit, schoolBus
    case federal, military, parkRanger, highway, otherFleet
    case privateVehicle
    case unknown

    public var isFleet: Bool {
        switch self {
        case .privateVehicle, .unknown: return false
        default: return true
        }
    }
}

/// A canonical taxpayer-funded vehicle record.
public struct Vehicle: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    public var primaryPlate: Plate?
    /// Fleet/unit number as painted on the vehicle ("UNIT 4421" → "4421").
    public var unitNumber: String?
    public var agencyID: UUID?
    public var kind: VehicleClass
    public var make: String?
    public var model: String?
    public var yearRange: ClosedRange<Int>?
    public var colors: [String]
    /// Anchor for re-identification of unplated vehicles (LSH-friendly hex).
    public var featurePrintAnchor: String?
    public var status: FleetStatus
    /// Every externally-sourced field must be backed by at least one entry.
    public var provenance: [SourceCitation]

    public enum FleetStatus: String, Sendable, Codable {
        case active, decommissioned, auctioned, unknown
    }

    public init(id: UUID = UUID(),
                primaryPlate: Plate? = nil,
                unitNumber: String? = nil,
                agencyID: UUID? = nil,
                kind: VehicleClass = .unknown,
                make: String? = nil,
                model: String? = nil,
                yearRange: ClosedRange<Int>? = nil,
                colors: [String] = [],
                featurePrintAnchor: String? = nil,
                status: FleetStatus = .unknown,
                provenance: [SourceCitation] = []) {
        self.id = id
        self.primaryPlate = primaryPlate
        self.unitNumber = unitNumber
        self.agencyID = agencyID
        self.kind = kind
        self.make = make
        self.model = model
        self.yearRange = yearRange
        self.colors = colors
        self.featurePrintAnchor = featurePrintAnchor
        self.status = status
        self.provenance = provenance
    }
}
