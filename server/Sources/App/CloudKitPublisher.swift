import Crypto
import Fluent
import Foundation
import Vapor

/// Moderator publication tool (docs/NEXT-STEPS.md §1b): copies accepted, aged, not-taken-down `Sighting` rows into the
/// world-readable CloudKit `Sighting` record type, and withdraws records whose row was taken down or passed retention.
/// App clients have no CREATE grant on that type, so only this server-to-server path can publish.
///
/// Everything here that decides *what* is published is pure and unit-tested; the network call in
/// `PublishCloudKitCommand` is a thin wrapper that needs the owner's CloudKit server-to-server key.
enum CloudKitPublisher {
    static let maxOperationsPerRequest = 100

    // MARK: planning

    struct Plan {
        var creates: [Sighting] = []
        var deletes: [Sighting] = []
    }

    /// Rows to publish and rows to withdraw. Mirrors `Sighting.publicQuery` plus the retention horizon so a row that is
    /// about to be purged is never newly published.
    static func plan(unpublished: [Sighting], published: [Sighting], policy: PublicationPolicy, now: Date = Date()) -> Plan {
        var plan = Plan()
        let publishCutoff = policy.publishCutoff(now: now), purgeCutoff = policy.purgeCutoff(now: now)
        for s in unpublished where s.id != nil && s.publishedAt == nil {
            guard s.moderationState == RedactionGateService.ModerationState.fleetConfirmed.rawValue,
                  !s.takenDown, s.capturedAt <= publishCutoff, s.capturedAt >= purgeCutoff else { continue }
            plan.creates.append(s)
        }
        for s in published where s.id != nil && s.publishedAt != nil {
            if s.takenDown || s.capturedAt < purgeCutoff { plan.deletes.append(s) }
        }
        return plan
    }

    // MARK: CloudKit Web Services payloads

    /// CloudKit TIMESTAMP values are milliseconds since the epoch.
    static func millis(_ d: Date) -> Int64 { Int64((d.timeIntervalSince1970 * 1000).rounded()) }

    /// Only schema fields for the `Sighting` type: ~1 km geohash cell (never exact coordinates, heading or device id),
    /// plate text only if the row carries one (the ingest gate only stores it for fleet-confirmed rows), and agency
    /// identity only when it is not flagged for review.
    static func createOperation(for s: Sighting) throws -> [String: Any] {
        var fields: [String: Any] = [
            "capturedAt": ["value": millis(s.capturedAt), "type": "TIMESTAMP"],
            "geohash6": ["value": s.geohash6, "type": "STRING"],
            "fleetConfidence": ["value": s.fleetConfidence, "type": "DOUBLE"],
            "moderationState": ["value": s.moderationState, "type": "STRING"],
        ]
        if let plate = s.plateText, !plate.isEmpty { fields["plateText"] = ["value": plate, "type": "STRING"] }
        if let unit = s.unitNumber, !unit.isEmpty { fields["unitNumber"] = ["value": unit, "type": "STRING"] }
        if s.agencyNeedsReview != true {
            if let key = s.agencyKey, !key.isEmpty { fields["agencyKey"] = ["value": key, "type": "STRING"] }
            if let name = s.agencyName, !name.isEmpty { fields["agencyName"] = ["value": name, "type": "STRING"] }
        }
        return ["operationType": "create",
                "record": ["recordType": "Sighting", "recordName": try s.requireID().uuidString, "fields": fields]]
    }

    static func deleteOperation(for s: Sighting) throws -> [String: Any] {
        ["operationType": "forceDelete", "record": ["recordType": "Sighting", "recordName": try s.requireID().uuidString]]
    }

    static func modifyBody(_ operations: [[String: Any]]) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["operations": operations], options: [.sortedKeys])
    }

    // MARK: server-to-server signing

    /// `/database/1/<container>/<environment>/public/records/modify`
    static func subpath(container: String, environment: String) -> String {
        "/database/1/\(container)/\(environment)/public/records/modify"
    }

    static func isoDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: date)
    }

    /// The signed message is `<ISO8601 date>:<base64 SHA-256 of body>:<subpath>`.
    static func signedMessage(date: String, body: Data, subpath: String) -> String {
        "\(date):\(Data(SHA256.hash(data: body)).base64EncodedString()):\(subpath)"
    }

    static func signature(date: String, body: Data, subpath: String, key: P256.Signing.PrivateKey) throws -> String {
        try key.signature(for: Data(signedMessage(date: date, body: body, subpath: subpath).utf8)).derRepresentation.base64EncodedString()
    }

    static func headers(keyID: String, date: String, signature: String) -> HTTPHeaders {
        [ "X-Apple-CloudKit-Request-KeyID": keyID,
          "X-Apple-CloudKit-Request-ISO8601Date": date,
          "X-Apple-CloudKit-Request-SignatureV1": signature,
          "Content-Type": "text/plain" ]
    }

    /// A per-record result. CloudKit reports `serverErrorCode` on failures; an existing record (retry after a lost
    /// response) counts as published, and deleting a missing record counts as withdrawn.
    static func succeeded(_ record: [String: Any], isDelete: Bool) -> Bool {
        guard let code = record["serverErrorCode"] as? String else { return true }
        return isDelete ? code == "NOT_FOUND" : code == "CONFLICT" || code == "EXISTS"
    }
}

struct AddSightingPublishedAt: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Sighting.schema).field("published_at", .datetime).update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(Sighting.schema).deleteField("published_at").update()
    }
}

/// `swift run App publish-cloudkit` — one publication pass. Needs `CK_CONTAINER`, `CK_KEY_ID`, `CK_PRIVATE_KEY_PATH`
/// (PEM, never committed) and optionally `CK_ENVIRONMENT` (`development` default, or `production`). `--dry-run` plans
/// and prints counts without any network call.
struct PublishCloudKitCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Flag(name: "dry-run", help: "Plan only; make no network request and change no row")
        var dryRun: Bool
    }
    var help: String { "Publish aged, moderated sightings to CloudKit and withdraw taken-down or expired ones." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        let policy = PublicationPolicy.fromEnvironment()
        let now = Date()
        let unpublished = try await Sighting.publicQuery(on: app.db, policy: policy, now: now)
            .filter(\.$publishedAt == nil).limit(CloudKitPublisher.maxOperationsPerRequest * 5).all()
        let published = try await Sighting.query(on: app.db).filter(\.$publishedAt != nil).limit(CloudKitPublisher.maxOperationsPerRequest * 5).all()
        let plan = CloudKitPublisher.plan(unpublished: unpublished, published: published, policy: policy, now: now)
        context.console.print("Plan: \(plan.creates.count) to publish, \(plan.deletes.count) to withdraw")
        if signature.dryRun || (plan.creates.isEmpty && plan.deletes.isEmpty) { return }

        guard let container = Environment.get("CK_CONTAINER"), let keyID = Environment.get("CK_KEY_ID"),
              let keyPath = Environment.get("CK_PRIVATE_KEY_PATH"),
              let pem = try? String(contentsOfFile: keyPath, encoding: .utf8),
              let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else {
            throw Abort(.internalServerError, reason: "CK_CONTAINER, CK_KEY_ID and a readable CK_PRIVATE_KEY_PATH are required")
        }
        let environment = Environment.get("CK_ENVIRONMENT") ?? "development"
        guard environment == "development" || environment == "production" else {
            throw Abort(.internalServerError, reason: "CK_ENVIRONMENT must be development or production")
        }

        // Withdrawals first, so retention is honoured even if a later batch fails.
        try await send(plan.deletes, isDelete: true, app: app, container: container, environment: environment, keyID: keyID, key: key) { row in
            row.publishedAt = nil
        }
        try await send(plan.creates, isDelete: false, app: app, container: container, environment: environment, keyID: keyID, key: key) { row in
            row.publishedAt = now
        }
    }

    private func send(_ rows: [Sighting], isDelete: Bool, app: Application, container: String, environment: String,
                      keyID: String, key: P256.Signing.PrivateKey, mark: (Sighting) -> Void) async throws {
        let path = CloudKitPublisher.subpath(container: container, environment: environment)
        for chunk in stride(from: 0, to: rows.count, by: CloudKitPublisher.maxOperationsPerRequest).map({ Array(rows[$0..<min($0 + CloudKitPublisher.maxOperationsPerRequest, rows.count)]) }) {
            let ops = try chunk.map { isDelete ? try CloudKitPublisher.deleteOperation(for: $0) : try CloudKitPublisher.createOperation(for: $0) }
            let body = try CloudKitPublisher.modifyBody(ops)
            let date = CloudKitPublisher.isoDate(Date())
            let sig = try CloudKitPublisher.signature(date: date, body: body, subpath: path, key: key)
            let response = try await app.client.post(URI(string: "https://api.apple-cloudkit.com\(path)"),
                                                     headers: CloudKitPublisher.headers(keyID: keyID, date: date, signature: sig)) {
                $0.body = ByteBuffer(data: body)
            }
            guard response.status == .ok, let data = response.body.map({ Data(buffer: $0) }),
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let records = json["records"] as? [[String: Any]] else {
                throw Abort(.badGateway, reason: "CloudKit returned \(response.status)")
            }
            for (row, record) in zip(chunk, records) where CloudKitPublisher.succeeded(record, isDelete: isDelete) {
                mark(row)
                try await row.save(on: app.db)
                await AuditEntry.record(isDelete ? "cloudkit.withdrawn" : "cloudkit.published", target: row.id?.uuidString, on: app.db)
            }
        }
    }
}
