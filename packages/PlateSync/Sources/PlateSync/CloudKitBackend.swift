import CloudKit
import Foundation
import PlateKit

/// The default backend: CloudKit **public database**, free tier.
///
/// The public database has only the default zone, and anything readable is
/// readable by everyone — so moderation state cannot live "next to" public
/// data. Two record families, separated by security role (see
/// `cloudkit/schema.ckdb`):
///   - `SightingSubmission`: what devices upload. Creator-only read; the world
///     cannot see it. A moderator (dashboard or server-to-server key) reviews
///     these and publishes accepted ones as…
///   - `Sighting` / `Vehicle` / `Agency`: world-readable, written only by the
///     moderator tooling, never by an app client.
/// Requires the CloudKit capability + container.
public struct CloudKitBackend: SyncBackend {

    public let container: CKContainer

    public init(containerIdentifier: String = "iCloud.org.platewatch.platewatch") {
        self.container = CKContainer(identifier: containerIdentifier)
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
        /// Device uploads. Creator-readable only.
        static let submission = "SightingSubmission"
        /// Moderated, world-readable.
        static let sighting = "Sighting"
        static let vehicle = "Vehicle"
        static let agency = "Agency"
    }

    /// Plate text is attached to an upload only when the same rule the REST
    /// server applies would make it public (fleet-confirmed: ≥ 0.8 with
    /// markings). Below that, the plate stays on the device.
    static func mayUploadPlate(_ sighting: SightingSubmissionDTO) -> Bool {
        let hasMarkings = sighting.markings?.agencyText != nil || sighting.markings?.unitNumber != nil
        // New Hub queues explicitly write false until local Review confirms the
        // evidence. Omitted remains compatible with legacy clients.
        let operatorConfirmed = sighting.userConfirmed ?? true
        return operatorConfirmed && sighting.fleetConfidence >= 0.8 && hasMarkings
    }

    // MARK: - SyncBackend

    public func submit(_ sighting: SightingSubmissionDTO,
                       idempotencyKey: String) async throws -> SubmissionReceipt {
        // Default zone: the public database supports no custom zones.
        let recordID = CKRecord.ID(recordName: "sighting-\(idempotencyKey)")
        // Same stable derivation pullSightings uses, so the receipt ID
        // matches the record even on idempotent replays.
        let stableID = Self.uuid(fromRecordName: idempotencyKey)
        let record = CKRecord(recordType: RecordType.submission, recordID: recordID)
        record["capturedAt"] = sighting.capturedAt as NSDate
        record["geohash6"] = sighting.geohash6
        record["deviceIDHash"] = sighting.deviceIDHash
        record["fleetConfidence"] = sighting.fleetConfidence
        record["userConfirmed"] = sighting.userConfirmed as NSNumber?
        if Self.mayUploadPlate(sighting) {
            record["plateText"] = sighting.plate?.text
            record["plateRegion"] = sighting.plate?.issuingRegion
        }
        record["unitNumber"] = sighting.markings?.unitNumber
        record["vehicleClass"] = sighting.vehicle.vehicleClass
        // Identity metadata describes the organisation and the plate's jurisdiction — never a person.
        // (The registration itself stays governed by `mayUploadPlate` above.)
        record["agencyKey"] = sighting.identity?.agency?.agencyKey
        record["agencyName"] = sighting.identity?.agency?.name
        record["agencyNeedsReview"] = sighting.identity?.agency.map { $0.needsReview ? 1 : 0 } as NSNumber?
        record["plateState"] = sighting.identity?.plate?.state
        record["moderationState"] = Sighting.ModerationState.pending.rawValue
        // Exact geo is deliberately withheld until fleet-confirmed server-side.

        do {
            let saved = try await publicDB.save(record)
            return SubmissionReceipt(sightingID: stableID,
                                     moderationState: .pending,
                                     serverReceivedAt: saved.modificationDate ?? Date(),
                                     idempotencyKey: idempotencyKey,
                                     operatorConfirmed: sighting.userConfirmed)
        } catch let error as CKError {
            switch error.code {
            case .quotaExceeded, .requestRateLimited: throw SyncError.quotaExceeded
            case .serverRecordChanged, .unknownItem:
                // Retry loop hit an existing idempotent write → treat published.
                return SubmissionReceipt(sightingID: stableID, moderationState: .pending,
                                         serverReceivedAt: Date(), idempotencyKey: idempotencyKey,
                                         operatorConfirmed: sighting.userConfirmed)
            case .notAuthenticated: throw SyncError.notAuthenticated
            default: throw SyncError.serverRejected(reason: error.localizedDescription)
            }
        }
    }

    /// CKQueryOperation.Cursor only round-trips through keyed archiving;
    /// a `String(describing:)` token cannot be unarchived and would force
    /// every pull back to page one.
    static func encodeCursor(_ cursor: CKQueryOperation.Cursor) -> String {
        let data = (try? NSKeyedArchiver.archivedData(withRootObject: cursor,
                                                      requiringSecureCoding: true)) ?? Data()
        return data.base64EncodedString()
    }

    static func decodeCursor(_ token: String) -> CKQueryOperation.Cursor? {
        guard let data = Data(base64Encoded: token) else { return nil }
        return try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKQueryOperation.Cursor.self,
                                                       from: data)
    }

    public func pullSightings(since cursor: SyncCursor?) async throws -> SightingDelta {
        let desiredKeys = ["capturedAt", "geohash6", "plateText", "unitNumber", "fleetConfidence",
                           "agencyKey", "agencyName"]
        let resultsLimit = 200
        let results: [(CKRecord.ID, Result<CKRecord, Error>)]
        let nextCursor: CKQueryOperation.Cursor?
        if let cursorObj = cursor.flatMap({ Self.decodeCursor($0.token) }) {
            (results, nextCursor) = try await publicDB.records(
                continuingMatchFrom: cursorObj,
                desiredKeys: desiredKeys,
                resultsLimit: resultsLimit)
        } else {
            // Fresh pull: newest first, so deltas read as "newest since the
            // last page" and the nightly export does the heavy lifting.
            // Only moderated records are ever read back — defence in depth on
            // top of the schema (clients cannot read SightingSubmission anyway).
            let query = CKQuery(recordType: RecordType.sighting,
                                predicate: NSPredicate(format: "moderationState == %@", "fleetConfirmed"))
            query.sortDescriptors = [NSSortDescriptor(key: "capturedAt", ascending: false)]
            (results, nextCursor) = try await publicDB.records(
                matching: query, inZoneWith: nil,
                desiredKeys: desiredKeys,
                resultsLimit: resultsLimit)
        }

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
                fleetConfidence: (record["fleetConfidence"] as? Double) ?? 0,
                agencyKey: record["agencyKey"] as? String,
                agencyName: record["agencyName"] as? String))
        }
        return SightingDelta(sightings: items,
                             newCursor: nextCursor.map { SyncCursor(token: Self.encodeCursor($0)) })
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

    public func agencies() async throws -> [PublicAgencyDTO] {
        let query = CKQuery(recordType: RecordType.agency, predicate: NSPredicate(value: true))
        let (results, _) = try await publicDB.records(matching: query, inZoneWith: nil,
                                                      desiredKeys: ["name", "shortName", "level", "parentAgencyID", "publicContactURL", "budgetURL"],
                                                      resultsLimit: 200)
        return results.compactMap { _, result in
            guard case .success(let record) = result else { return nil }
            return PublicAgencyDTO(id: Self.uuid(fromRecordName: record.recordID.recordName),
                                   name: record["name"] as? String ?? "Unknown agency",
                                   shortName: record["shortName"] as? String,
                                   level: record["level"] as? String ?? "unknown",
                                   parentAgencyID: (record["parentAgencyID"] as? String).flatMap(UUID.init),
                                   publicContactURL: record["publicContactURL"] as? String,
                                   budgetURL: record["budgetURL"] as? String)
        }
    }

    public func agencyReport(id: UUID) async throws -> AgencyReportDTO {
        throw SyncError.unsupported
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
