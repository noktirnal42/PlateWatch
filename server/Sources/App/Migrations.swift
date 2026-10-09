import Fluent
import SQLKit
import Foundation

struct CreateVehicles: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Vehicle.schema)
            .id()
            .field("plate_text", .string)
            .field("plate_region", .string)
            .field("plate_design", .string)
            .field("unit_number", .string)
            .field("agency_id", .uuid, .references("agencies", "id"))
            .field("kind", .string, .required)
            .field("make", .string)
            .field("model", .string)
            .field("status", .string, .required)
            .field("sightings_count", .int, .required, .sql(.default(0)))
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "plate_text", "plate_region")
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(Vehicle.schema).delete()
    }
}

struct CreateAgencies: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Agency.schema)
            .id()
            .field("name", .string, .required)
            .field("short_name", .string)
            .field("level", .string, .required)
            .field("jurisdiction_geojson", .string)
            .field("parent_agency_id", .uuid, .references("agencies", "id"))
            .field("public_contact_url", .string)
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(Agency.schema).delete()
    }
}

struct CreateUnitAssignments: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(UnitAssignment.schema)
            .id()
            .field("agency_id", .uuid, .required, .references("agencies", "id"))
            .field("unit_number", .string, .required)
            .field("vehicle_id", .uuid, .references("vehicles", "id"))
            .field("subject_name", .string)
            .field("role", .string, .required)
            .field("confidence", .string, .required)
            .field("provenance_json", .string, .required)
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(UnitAssignment.schema).delete()
    }
}

struct CreateSightings: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Sighting.schema)
            .id()
            .field("vehicle_id", .uuid, .references("vehicles", "id"))
            .field("plate_text", .string)
            .field("captured_at", .datetime, .required)
            .field("geohash6", .string, .required)
            .field("exact_lat", .double)
            .field("exact_lon", .double)
            .field("heading_deg", .float)
            .field("crop_sha256", .string)
            .field("device_id_hash", .string, .required)
            .field("fleet_confidence", .double, .required)
            .field("moderation_state", .string, .required)
            .field("idempotency_key", .string, .required)
            .unique(on: "idempotency_key")
            .create()
        // Query paths: recent-by-plate and bucketed heatmaps.
        if let sql = database as? any SQLDatabase {
            try await sql.raw("""
                CREATE INDEX IF NOT EXISTS sightings_plate_time
                ON sightings (plate_text, captured_at DESC)
                """).run()
        }
    }
    func revert(on database: any Database) async throws {
        try await database.schema(Sighting.schema).delete()
    }
}

struct CreateDeviceReputations: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(DeviceReputation.schema)
            .id()
            .field("device_id_hash", .string, .required)
            .field("score", .int, .required)
            .field("banned_reason", .string)
            .unique(on: "device_id_hash")
            .create()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(DeviceReputation.schema).delete()
    }
}
