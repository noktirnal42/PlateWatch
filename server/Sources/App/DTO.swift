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

struct VehicleObservationDTO: Content {
    var vehicleClass: String
    var classConfidence: Double
    var hasLightBar: Bool?
    var hasPushBar: Bool?
    var hasFleetDecals: Bool?
}

struct FleetMarkingsDTO: Content {
    var agencyText: String?
    var unitNumber: String?
    var serviceClassText: String?
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
}
