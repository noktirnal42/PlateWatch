import Foundation

/// Wire protocol shared by the CloudKit backend (mapped to fields) and the
/// REST reference server (encoded verbatim). All DTOs are field-compatible
/// with `server/Sources/App/DTO`.

public struct SightingSubmissionDTO: Sendable, Codable {
    public var capturedAt: Date
    public var geohash6: String
    public var exactLatitude: Double?
    public var exactLongitude: Double?
    public var headingDegrees: Float?
    public var roadClass: String?
    public var cropHashSHA256: String?
    public var cropJPEGBase64: String?     // ≤40 KB thumbnails only
    public var deviceIDHash: String
    public var fleetConfidence: Double
    public var plate: PlateDTO?
    public var vehicle: VehicleObservationDTO
    public var markings: FleetMarkingsDTO?
    /// Structured, cross-referenceable identity (agency key, plate jurisdiction, unit, evidence).
    /// Optional: servers that predate it ignore the key. The plate inside it follows the same
    /// redaction rule as `plate` — stripped unless the sighting is allowed to carry one.
    public var identity: VehicleIdentity?

    public init(capturedAt: Date, geohash6: String, exactLatitude: Double? = nil,
                exactLongitude: Double? = nil, headingDegrees: Float? = nil,
                roadClass: String? = nil, cropHashSHA256: String? = nil,
                cropJPEGBase64: String? = nil, deviceIDHash: String,
                fleetConfidence: Double, plate: PlateDTO? = nil,
                vehicle: VehicleObservationDTO, markings: FleetMarkingsDTO? = nil,
                identity: VehicleIdentity? = nil) {
        self.identity = identity
        self.capturedAt = capturedAt
        self.geohash6 = geohash6
        self.exactLatitude = exactLatitude
        self.exactLongitude = exactLongitude
        self.headingDegrees = headingDegrees
        self.roadClass = roadClass
        self.cropHashSHA256 = cropHashSHA256
        self.cropJPEGBase64 = cropJPEGBase64
        self.deviceIDHash = deviceIDHash
        self.fleetConfidence = fleetConfidence
        self.plate = plate
        self.vehicle = vehicle
        self.markings = markings
    }
}

public struct PlateDTO: Sendable, Codable {
    public var text: String
    public var issuingRegion: String?
    public var country: String
    public var plateDesign: String?
    public var confidence: Double

    public init(text: String, issuingRegion: String? = nil, country: String = "US",
                plateDesign: String? = nil, confidence: Double = 0) {
        self.text = text; self.issuingRegion = issuingRegion; self.country = country
        self.plateDesign = plateDesign; self.confidence = confidence
    }

    public init(_ plate: Plate) {
        self.init(text: plate.text, issuingRegion: plate.issuingRegion,
                  country: plate.country, plateDesign: plate.plateDesign,
                  confidence: plate.confidence)
    }
}

public struct VehicleObservationDTO: Sendable, Codable {
    public var vehicleClass: String
    public var classConfidence: Double
    public var attributes: VehicleAttributes?

    public init(vehicleClass: String, classConfidence: Double, attributes: VehicleAttributes? = nil) {
        self.vehicleClass = vehicleClass
        self.classConfidence = classConfidence
        self.attributes = attributes
    }

    public init(_ obs: VehicleObservation) {
        self.init(vehicleClass: obs.vehicleClass.rawValue,
                  classConfidence: obs.classConfidence, attributes: obs.attributes)
    }
}

public struct FleetMarkingsDTO: Sendable, Codable {
    public var agencyText: String?
    public var unitNumber: String?
    public var serviceClassText: String?
    /// Free-text field note (watch dictation). Optional — servers that
    /// predate this field simply ignore it on decode.
    public var note: String?

    public init(agencyText: String? = nil, unitNumber: String? = nil,
                serviceClassText: String? = nil, note: String? = nil) {
        self.agencyText = agencyText
        self.unitNumber = unitNumber
        self.serviceClassText = serviceClassText
        self.note = note
    }

    public init(_ markings: FleetMarkings) {
        self.init(agencyText: markings.agencyText, unitNumber: markings.unitNumber,
                  serviceClassText: markings.serviceClassText)
    }
}

/// Server/mirror → client read models.
public struct PublicVehicleDTO: Sendable, Codable {
    public var id: UUID
    public var plateText: String?
    public var unitNumber: String?
    public var agencyName: String?
    public var kind: String
    public var make: String?
    public var model: String?
    public var status: String
    public var sightingsCount: Int

    public init(id: UUID, plateText: String? = nil, unitNumber: String? = nil,
                agencyName: String? = nil, kind: String, make: String? = nil,
                model: String? = nil, status: String, sightingsCount: Int) {
        self.id = id; self.plateText = plateText; self.unitNumber = unitNumber
        self.agencyName = agencyName; self.kind = kind; self.make = make
        self.model = model; self.status = status; self.sightingsCount = sightingsCount
    }
}

public struct PublicAgencyDTO: Sendable, Codable {
    public var id: UUID
    public var name: String
    public var level: String
    public var parentAgencyID: UUID?

    public init(id: UUID, name: String, level: String, parentAgencyID: UUID? = nil) {
        self.id = id; self.name = name; self.level = level
        self.parentAgencyID = parentAgencyID
    }
}

public struct SightingPageDTO: Sendable, Codable {
    public var items: [PublicSightingDTO]
    public var nextCursor: String?

    public init(items: [PublicSightingDTO], nextCursor: String? = nil) {
        self.items = items
        self.nextCursor = nextCursor
    }
}

public struct PublicSightingDTO: Sendable, Codable {
    public var id: UUID
    public var capturedAt: Date
    public var geohash6: String
    public var plateText: String?
    public var unitNumber: String?
    public var fleetConfidence: Double
    /// Cross-reference join key ("US-MA/waltham/police") and display name — only present
    /// when the identity was confident (not flagged for review).
    public var agencyKey: String?
    public var agencyName: String?

    public init(id: UUID, capturedAt: Date, geohash6: String,
                plateText: String? = nil, unitNumber: String? = nil,
                fleetConfidence: Double = 0, agencyKey: String? = nil, agencyName: String? = nil) {
        self.agencyKey = agencyKey; self.agencyName = agencyName
        self.id = id; self.capturedAt = capturedAt; self.geohash6 = geohash6
        self.plateText = plateText; self.unitNumber = unitNumber
        self.fleetConfidence = fleetConfidence
    }
}
