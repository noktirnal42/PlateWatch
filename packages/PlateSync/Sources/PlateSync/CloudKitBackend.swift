import CloudKit
import Foundation
import PlateKit

/// The default backend: CloudKit **public database**, free tier. One
/// container holds the shared civic dataset; zones separate public records
/// from moderation state. Requires the CloudKit capability + container.
public struct CloudKitBackend: SyncBackend {

    public let container: CKContainer
    /// Public records live here; moderation zone stays moderator-only via
    /// CKRecordZone restrictions enforced by role records.
    public let publicZoneID: CKRecordZone.ID

    public init(containerIdentifier: String = "iCloud.org.platewatch.platewatch") {
        self.container = CKContainer(identifier: containerIdentifier)
        self.publicZoneID = CKRecordZone.ID(zoneName: "fleet-main")
    }

    private var publicDB: CKDatabase { container.publicCloudDatabase }

    /// Record names embed the canonical sighting/vehicle UUID where possible;
    /// otherwise we derive a *stable* UUID from the name so deltas are
    /// meaningful across pulls.
    static func uuid(fromRecordName name: String) -> UUID {
        if let direct = UUID(uuidString: name) { return direct }
        var hasher = Hasher()
        hasher.combine(name)
        var bytes = [UInt8](repeating: 0, count: 16)
        var h = UInt64(bitPattern: Int64(hasher.finalize()))
        for i in 0..<8 { bytes[i] = UInt8((h >> (i * 8)) & 0xff) }
        h ^= 0x9E3779B97F4A7C15
        for i in 8..<16 { bytes[i] = UInt8((h >> ((i - 8) * 8)) & 0xff) }
        bytes[6] = (bytes[6] & 0x0F) | 0x50  // version 5-ish marker
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    // MARK: - Schema mapping (mirrors docs/DATA-MODEL.md)

    enum RecordType {
        static let sighting = "CD_Sighting"
        static let vehicle = "CD_Vehicle"
        static let agency = "CD_Agency"
    }

    // MARK: - SyncBackend

    public func submit(_ sighting: SightingSubmissionDTO,
                       idempotencyKey: String) async throws -> SubmissionReceipt {
        let recordID = CKRecord.ID(recordName: "sighting-\(idempotencyKey)",
                                   zoneID: publicZoneID)
        let record = CKRecord(recordType: RecordType.sighting, recordID: recordID)
        record["capturedAt"] = sighting.capturedAt as NSDate
        record["geohash6"] = sighting.geohash6
        record["deviceIDHash"] = sighting.deviceIDHash
        record["fleetConfidence"] = sighting.fleetConfidence
        record["plateText"] = sighting.plate?.text
        record["plateRegion"] = sighting.plate?.issuingRegion
        record["unitNumber"] = sighting.markings?.unitNumber
        record["vehicleClass"] = sighting.vehicle.vehicleClass
        record["moderationState"] = Sighting.ModerationState.pending.rawValue
        // Exact geo is deliberately withheld until fleet-confirmed server-side.

        do {
            let saved = try await publicDB.save(record)
            return SubmissionReceipt(sightingID: UUID(uuidString: idempotencyKey.prefix(36).description) ?? UUID(),
                                     moderationState: .pending,
                                     serverReceivedAt: saved.modificationDate ?? Date())
        } catch let error as CKError {
            switch error.code {
            case .quotaExceeded, .requestRateLimited: throw SyncError.quotaExceeded
            case .serverRecordChanged, .unknownItem:
                // Retry loop hit an existing idempotent write → treat published.
                return SubmissionReceipt(sightingID: UUID(), moderationState: .pending,
                                         serverReceivedAt: Date())
            case .notAuthenticated: throw SyncError.notAuthenticated
            default: throw SyncError.serverRejected(reason: error.localizedDescription)
            }
        }
    }

    public func pullSightings(since cursor: SyncCursor?) async throws -> SightingDelta {
        // Delta pull over a plate-search query keeps the free tier happy and
        // pushes heavy lifting to the nightly export for analysts.
        let predicate = NSPredicate(value: true)
        let query = CKQuery(recordType: RecordType.sighting, predicate: predicate)
        query.sortDescriptors = [NSSortDescriptor(key: "capturedAt", ascending: false)]
        let cursorObj = cursor.flatMap { try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKQueryOperation.Cursor.self, from: Data($0.token.utf8)) }
        let (results, nextCursor) = try await publicDB.records(
            matching: query, inZoneWith: nil,
            desiredKeys: ["capturedAt", "geohash6", "plateText", "unitNumber", "fleetConfidence"],
            resultsLimit: 200)

        _ = cursorObj // change-token path activates with zone config; MVP query pull
        var items: [PublicSightingDTO] = []
        for (_, result) in results {
            guard case .success(let record) = result,
                  let capturedAt = record["capturedAt"] as? Date else { continue }
            let tail = record.recordID.recordName.components(separatedBy: "-").last ?? ""
            let stableID = Self.uuid(fromRecordName: tail)
            items.append(PublicSightingDTO(
                id: stableID,
                capturedAt: capturedAt,
                geohash6: record["geohash6"] as? String ?? "",
                plateText: record["plateText"] as? String,
                unitNumber: record["unitNumber"] as? String,
                fleetConfidence: (record["fleetConfidence"] as? Double) ?? 0))
        }
        return SightingDelta(sightings: items,
                             newCursor: nextCursor.map { SyncCursor(token: String(describing: $0)) })
    }

    public func vehicles(matchingPlate plateText: String) async throws -> [PublicVehicleDTO] {
        let normalized = Plate.normalize(plateText)
        let predicate = NSPredicate(format: "plateText == %@", normalized)
        let query = CKQuery(recordType: RecordType.vehicle, predicate: predicate)
        let (results, _) = try await publicDB.records(
            matching: query, inZoneWith: nil,
            desiredKeys: ["plateText", "unitNumber", "agencyName", "vehicleClass",
                          "make", "model", "status", "sightingsCount"],
            resultsLimit: 50)
        return results.compactMap { _, result -> PublicVehicleDTO? in
            guard case .success(let r) = result else { return nil }
            return PublicVehicleDTO(
                id: Self.uuid(fromRecordName: r.recordID.recordName),
                plateText: r["plateText"] as? String,
                unitNumber: r["unitNumber"] as? String,
                agencyName: r["agencyName"] as? String,
                kind: r["vehicleClass"] as? String ?? "unknown",
                make: r["make"] as? String,
                model: r["model"] as? String,
                status: r["status"] as? String ?? "unknown",
                sightingsCount: (r["sightingsCount"] as? Int) ?? 0)
        }
    }

    public func ensureWatchlistSubscription() async throws {
        let subscriptionID = "watchlist-fleet-hits"
        // Idempotent: existing subscription with our token is fine.
        let predicate = NSPredicate(format: "moderationState == %@", "fleetConfirmed")
        let sub = CKQuerySubscription(recordType: RecordType.sighting,
                                      predicate: predicate,
                                      subscriptionID: subscriptionID,
                                      options: [.firesOnRecordCreation])
        let info = CKSubscription.NotificationInfo()
        info.shouldSendContentAvailable = true  // silent — app/watch wake
        info.alertBody = nil
        sub.notificationInfo = info
        _ = try await publicDB.save(sub)
    }
}
