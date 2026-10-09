import Foundation
import PlateKit
import SwiftData

/// Offline-first submission queue. Detections are persisted on-device the
/// moment the RedactionGate approves them and sync retries later — a dead
/// zone must never lose evidence.
@Model
public final class PendingSubmission {
    @Attribute(.unique) public var idempotencyKey: String
    public var createdAt: Date
    public var payloadJSON: Data   // SightingSubmissionDTO
    public var retryCount: Int
    public var lastError: String?

    public init(idempotencyKey: String, payloadJSON: Data,
                createdAt: Date = Date(), retryCount: Int = 0, lastError: String? = nil) {
        self.idempotencyKey = idempotencyKey
        self.payloadJSON = payloadJSON
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.lastError = lastError
    }
}

/// Drains `PendingSubmission` rows through the active backend with
/// exponential backoff. Safe against duplicate delivery (idempotency keys).
public actor OutboxDrainer {
    public let backend: any SyncBackend
    /// Max attempts before parking a row for manual review.
    public var maxRetries = 8

    public init(backend: any SyncBackend) {
        self.backend = backend
    }

    public static func idempotencyKey(for dto: SightingSubmissionDTO) -> String {
        // Content-addressed: same detection re-submitted = same key.
        // (Device key id is folded in upstream when signing.)
        var hasher = Hasher()
        hasher.combine(dto.capturedAt.timeIntervalSince1970)
        hasher.combine(dto.geohash6)
        hasher.combine(dto.plate?.text)
        hasher.combine(dto.vehicle.vehicleClass)
        hasher.combine(dto.cropHashSHA256)
        return String(format: "%016llx", UInt64(bitPattern: Int64(hasher.finalize())))
    }

    public func drain(context: ModelContext) async {
        let descriptor = FetchDescriptor<PendingSubmission>(
            sortBy: [SortDescriptor(\PendingSubmission.createdAt)])
        guard let rows = try? context.fetch(descriptor) else { return }

        for row in rows where row.retryCount < maxRetries {
            guard let dto = try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self,
                                                                 from: row.payloadJSON) else {
                context.delete(row); continue // unparseable = permanently broken row
            }
            do {
                _ = try await backend.submit(dto, idempotencyKey: row.idempotencyKey)
                context.delete(row)
            } catch SyncError.quotaExceeded {
                return // back off whole run; next drain will resume in order
            } catch {
                row.retryCount += 1
                row.lastError = String(describing: error)
            }
        }
        try? context.save()
    }
}

extension JSONDecoder {
    static var withISODates: JSONDecoder {
        let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d
    }
}

extension JSONEncoder {
    public static var withISODates: JSONEncoder {
        let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e
    }
}
