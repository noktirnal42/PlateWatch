import Crypto
import Fluent
import Foundation
import Vapor

/// Content-free record that an observation was withdrawn by an upheld takedown (docs/FEED-SOURCES.md §6b). After the
/// sighting row is purged by retention, a device that retries the same observation (same idempotency key or same crop
/// hash) is refused instead of being re-ingested and re-published. Only salted-free SHA-256 digests of those keys are
/// stored — never a plate, location, unit number or device id.
final class Tombstone: Model, @unchecked Sendable {
    static let schema = "tombstones"
    @ID(key: .id) var id: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Field(key: "key_hash") var keyHash: String
    init() {}
    init(keyHash: String) { self.keyHash = keyHash }

    /// Digests that identify one observation. Namespaced so an idempotency key can never collide with a crop hash.
    static func keyHashes(idempotencyKey: String?, cropSHA256: String?) -> [String] {
        var out: [String] = []
        if let k = idempotencyKey, !k.isEmpty { out.append(digest("idem:" + k)) }
        if let c = cropSHA256, !c.isEmpty { out.append(digest("crop:" + c.lowercased())) }
        return out
    }

    private static func digest(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func isWithdrawn(idempotencyKey: String?, cropSHA256: String?, on db: any Database) async throws -> Bool {
        let hashes = keyHashes(idempotencyKey: idempotencyKey, cropSHA256: cropSHA256)
        guard !hashes.isEmpty else { return false }
        return try await Tombstone.query(on: db).filter(\.$keyHash ~~ hashes).count() > 0
    }

    /// Records tombstones for a sighting that was taken down. Idempotent.
    static func record(for sighting: Sighting, on db: any Database) async throws {
        for hash in keyHashes(idempotencyKey: sighting.idempotencyKey, cropSHA256: sighting.cropSHA256) {
            if try await Tombstone.query(on: db).filter(\.$keyHash == hash).count() == 0 {
                try await Tombstone(keyHash: hash).save(on: db)
            }
        }
    }
}

struct CreateTombstones: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Tombstone.schema)
            .id()
            .field("created_at", .datetime)
            .field("key_hash", .string, .required)
            .unique(on: "key_hash")
            .create()
    }
    func revert(on database: any Database) async throws { try await database.schema(Tombstone.schema).delete() }
}
