import Fluent
import Foundation

/// Fluent model mirroring PlateKit.Vehicle. Field-compatible by convention —
/// CI compiles both, docs/DATA-MODEL.md is the contract.
final class Vehicle: Model, @unchecked Sendable {
    static let schema = "vehicles"

    @ID(key: .id) var id: UUID?
    @OptionalField(key: "plate_text") var plateText: String?
    @OptionalField(key: "plate_region") var plateRegion: String?
    @OptionalField(key: "plate_design") var plateDesign: String?
    @OptionalField(key: "unit_number") var unitNumber: String?
    @OptionalParent(key: "agency_id") var agency: Agency?
    @Field(key: "kind") var kind: String
    @OptionalField(key: "make") var make: String?
    @OptionalField(key: "model") var model: String?
    @Field(key: "status") var status: String
    @Field(key: "sightings_count") var sightingsCount: Int
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Timestamp(key: "updated_at", on: .update) var updatedAt: Date?

    init() {}
}

final class Agency: Model, @unchecked Sendable {
    static let schema = "agencies"

    @ID(key: .id) var id: UUID?
    @Field(key: "name") var name: String
    @OptionalField(key: "short_name") var shortName: String?
    @Field(key: "level") var level: String
    @OptionalField(key: "jurisdiction_geojson") var jurisdictionGeoJSON: String?
    @OptionalParent(key: "parent_agency_id") var parentAgency: Agency?
    @OptionalField(key: "public_contact_url") var publicContactURL: String?

    init() {}
}

/// Unit number ↔ vehicle ↔ (cited) roster name. Provenance is mandatory:
/// an assignment without at least one citation JSON row fails validation.
final class UnitAssignment: Model, @unchecked Sendable {
    static let schema = "unit_assignments"

    @ID(key: .id) var id: UUID?
    @Parent(key: "agency_id") var agency: Agency
    @Field(key: "unit_number") var unitNumber: String
    @OptionalParent(key: "vehicle_id") var vehicle: Vehicle?
    @OptionalField(key: "subject_name") var subjectName: String?
    @Field(key: "role") var role: String
    @Field(key: "confidence") var confidence: String
    @Field(key: "provenance_json") var provenanceJSON: String

    init() {}
}

final class Sighting: Model, @unchecked Sendable {
    static let schema = "sightings"

    @ID(key: .id) var id: UUID?
    @OptionalParent(key: "vehicle_id") var vehicle: Vehicle?
    @OptionalField(key: "plate_text") var plateText: String?
    /// Parsed unit/fleet number — the join key into agency rosters.
    /// Nullable pre-enrichment; exports surface it when present.
    @OptionalField(key: "unit_number") var unitNumber: String?
    @Field(key: "captured_at") var capturedAt: Date
    @Field(key: "geohash6") var geohash6: String
    @OptionalField(key: "exact_lat") var exactLat: Double?
    @OptionalField(key: "exact_lon") var exactLon: Double?
    @OptionalField(key: "heading_deg") var headingDeg: Float?
    @OptionalField(key: "crop_sha256") var cropSHA256: String?
    @Field(key: "device_id_hash") var deviceIDHash: String
    @Field(key: "fleet_confidence") var fleetConfidence: Double
    @Field(key: "moderation_state") var moderationState: String
    /// Idempotency dedupe — replays return the original receipt.
    @Field(key: "idempotency_key") var idempotencyKey: String

    init() {}
}

/// Rate-limit / abuse scores keyed by ed25519 device key hash.
final class DeviceReputation: Model, @unchecked Sendable {
    static let schema = "device_reputations"

    @ID(key: .id) var id: UUID?
    @Field(key: "device_id_hash") var deviceIDHash: String
    @Field(key: "score") var score: Int
    @OptionalField(key: "banned_reason") var bannedReason: String?

    init() {}
}
