import Foundation
import Vapor

/// Wire DTOs — the cross-platform protocol. MUST stay field-compatible with
/// packages/PlateKit/Sources/PlateKit/DTO/SyncDTOs.swift. CI compiles both;
/// the checklist for changes lives in docs/DATA-MODEL.md.

struct PlateDTO: Content {
    var text: String
    var issuingRegion: String?
    var country: String
    var plateDesign: String?
    var confidence: Double
}

/// Field-compatible with PlateKit.VehicleAttributes (SyncDTOs.swift).
struct VehicleAttributesDTO: Content {
    var make: String?
    var model: String?
    var color: String?
    var bodyType: String?
    var hasLightBar: Bool?
    var hasPushBar: Bool?
    var hasFleetDecals: Bool?
}

struct VehicleObservationDTO: Content {
    var vehicleClass: String
    var classConfidence: Double
    var attributes: VehicleAttributesDTO?
}

struct FleetMarkingsDTO: Content {
    var agencyText: String?
    var unitNumber: String?
    var serviceClassText: String?
    /// Free-text field note (watch dictation). Optional — decoded from
    /// newer clients, absent in older payloads.
    var note: String?
}

struct SightingSubmissionDTO: Content {
    var capturedAt: Date
    var geohash6: String
    var exactLatitude: Double?
    var exactLongitude: Double?
    var headingDegrees: Float?
    var roadClass: String?
    var cropHashSHA256: String?
    var cropJPEGBase64: String?
    var deviceIDHash: String
    var fleetConfidence: Double
    var plate: PlateDTO?
    var vehicle: VehicleObservationDTO
    var markings: FleetMarkingsDTO?
    /// Operator confirmation from the local review queue. Missing/false stays
    /// pending until an enrolled moderator makes the publication decision.
    var userConfirmed: Bool?
    /// Mirrors PlateKit's `VehicleIdentity` — only the fields the server indexes; the rest of the
    /// client's JSON is ignored on decode.
    var identity: IdentityDTO?
}

struct IdentityDTO: Content {
    var agency: AgencyIdentityDTO?
    var plate: PlateIdentityDTO?
}

struct AgencyIdentityDTO: Content {
    var name: String
    var service: String?
    var place: String?
    var state: String?
    var agencyKey: String
    var confidence: Double
    var needsReview: Bool
}

struct PlateIdentityDTO: Content {
    /// USPS state code the plate was issued in ("MA"). The registration itself is never read here:
    /// plate text follows the existing fleet-confirmed-only rule via `plate`.
    var state: String?
}

struct SubmissionReceiptDTO: Content {
    var sightingID: UUID
    var moderationState: String
    var serverReceivedAt: Date
}

struct PublicSightingDTO: Content {
    var id: UUID
    var capturedAt: Date
    var geohash6: String
    var plateText: String?
    var unitNumber: String?
    var fleetConfidence: Double
    var agencyKey: String?
    var agencyName: String?
}

struct SightingPageDTO: Content {
    var items: [PublicSightingDTO]
    var nextCursor: String?
}

struct PublicVehicleDTO: Content {
    var id: UUID
    var plateText: String?
    var unitNumber: String?
    var agencyName: String?
    var kind: String
    var make: String?
    var model: String?
    var status: String
    var sightingsCount: Int
}

struct AgencyDTO: Content {
    var id: UUID
    var name: String
    var shortName: String?
    var level: String
    var parentAgencyID: UUID?
    var publicContactURL: String?
    var budgetURL: String?
}
