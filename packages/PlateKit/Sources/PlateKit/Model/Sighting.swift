import Foundation

/// One observation of a vehicle in the world. The atomic unit of the shared
/// dataset. Deliberately carries no audio and only a small plate crop.
public struct Sighting: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    public var vehicleID: UUID?
    public var plateText: String?
    public var capturedAt: Date
    /// Coarse geo in ~1 km buckets set pre-upload; exact geo is applied only
    /// for fleet-confirmed sightings (see `RedactionGate` / LEGAL-ETHICS).
    public var geoBucket: GeoBucket
    public var headingDegrees: Float?
    public var roadClass: String?
    /// SHA-256 of the stored plate crop (≤40 KB) — evidence integrity anchor.
    public var cropHashSHA256: String?
    /// Reference to the crop asset (CloudKit asset or REST object key).
    public var cropAssetRef: String?
    /// ed25519 pubkey hash of the capturing device.
    public var deviceIDHash: String
    public var moderationState: ModerationState
    /// Output of the on-device fleet classifier, 0…1.
    public var fleetConfidence: Double

    public enum ModerationState: String, Sendable, Codable {
        case pending, fleetConfirmed, redacted, rejected
    }

    public init(id: UUID = UUID(),
                vehicleID: UUID? = nil,
                plateText: String? = nil,
                capturedAt: Date,
                geoBucket: GeoBucket,
                headingDegrees: Float? = nil,
                roadClass: String? = nil,
                cropHashSHA256: String? = nil,
                cropAssetRef: String? = nil,
                deviceIDHash: String,
                moderationState: ModerationState = .pending,
                fleetConfidence: Double = 0) {
        self.id = id
        self.vehicleID = vehicleID
        self.plateText = plateText
        self.capturedAt = capturedAt
        self.geoBucket = geoBucket
        self.headingDegrees = headingDegrees
        self.roadClass = roadClass
        self.cropHashSHA256 = cropHashSHA256
        self.cropAssetRef = cropAssetRef
        self.deviceIDHash = deviceIDHash
        self.moderationState = moderationState
        self.fleetConfidence = min(1, max(0, fleetConfidence))
    }
}

/// Privacy-grade location representation. Exact coordinates are stored only
/// after fleet confirmation.
public struct GeoBucket: Sendable, Codable, Hashable {
    /// Geohash-6 (~610 m×610 m) for the default shared view.
    public var geohash6: String
    /// Exact coordinates; present only for fleet-confirmed records.
    public var exactLatitude: Double?
    public var exactLongitude: Double?

    public init(geohash6: String, exactLatitude: Double? = nil, exactLongitude: Double? = nil) {
        self.geohash6 = geohash6
        self.exactLatitude = exactLatitude
        self.exactLongitude = exactLongitude
    }
}

/// User-scoped watchlist entry. Never published to the shared dataset.
public struct WatchlistEntry: Sendable, Identifiable, Codable, Hashable {
    public let id: UUID
    public var vehicleID: UUID?
    public var plateText: String?
    public var featurePrintAnchor: String?
    public var notifyOnMatch: Bool

    public init(id: UUID = UUID(), vehicleID: UUID? = nil, plateText: String? = nil,
                featurePrintAnchor: String? = nil, notifyOnMatch: Bool = true) {
        self.id = id
        self.vehicleID = vehicleID
        self.plateText = plateText
        self.featurePrintAnchor = featurePrintAnchor
        self.notifyOnMatch = notifyOnMatch
    }

    /// Deterministic match check used by on-device alert evaluation.
    public func matches(plate: Plate?, featureAnchor: String?) -> Bool {
        if let want = plateText?.uppercased(), let plate {
            return plate.text == Plate.normalize(want)
        }
        if let want = featurePrintAnchor, let featureAnchor, want == featureAnchor {
            return true
        }
        return false
    }
}
