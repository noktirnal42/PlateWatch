import Crypto
import XCTest
@testable import App

final class PublicationSafeguardTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let policy = PublicationPolicy.parse(delayHours: "24", retentionDays: "21")

    private func sighting(ageHours: Double, state: String = "fleetConfirmed", takenDown: Bool = false, published: Bool = false) -> Sighting {
        let s = Sighting()
        s.id = UUID()
        s.capturedAt = now.addingTimeInterval(-ageHours * 3600)
        s.geohash6 = "9q8yyk"
        s.fleetConfidence = 0.9
        s.moderationState = state
        s.takenDown = takenDown
        s.deviceIDHash = "dev"
        s.idempotencyKey = "idem-\(UUID().uuidString)"
        s.exactLat = 37.77; s.exactLon = -122.41; s.headingDeg = 90
        if published { s.publishedAt = now.addingTimeInterval(-3600) }
        return s
    }

    // MARK: tombstones

    func testTombstoneKeysAreNamespacedHashesNotContent() {
        let keys = Tombstone.keyHashes(idempotencyKey: "abc", cropSHA256: "ABC")
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1], "idempotency and crop digests never collide")
        XCTAssertTrue(keys.allSatisfy { $0.count == 64 && !$0.contains("abc") })
        XCTAssertEqual(Tombstone.keyHashes(idempotencyKey: nil, cropSHA256: nil), [])
        XCTAssertEqual(Tombstone.keyHashes(idempotencyKey: nil, cropSHA256: "ABC"), Tombstone.keyHashes(idempotencyKey: nil, cropSHA256: "abc"))
    }

    // MARK: publication planning

    func testOnlyAgedConfirmedLiveRowsArePublished() {
        let ok = sighting(ageHours: 30)
        let tooFresh = sighting(ageHours: 2)
        let pending = sighting(ageHours: 30, state: "pending")
        let down = sighting(ageHours: 30, takenDown: true)
        let expired = sighting(ageHours: 24 * 22)
        let plan = CloudKitPublisher.plan(unpublished: [ok, tooFresh, pending, down, expired], published: [], policy: policy, now: now)
        XCTAssertEqual(plan.creates.map(\.id), [ok.id])
        XCTAssertTrue(plan.deletes.isEmpty)
    }

    func testTakenDownAndExpiredPublishedRowsAreWithdrawn() {
        let live = sighting(ageHours: 30, published: true)
        let down = sighting(ageHours: 30, takenDown: true, published: true)
        let expired = sighting(ageHours: 24 * 22, published: true)
        let plan = CloudKitPublisher.plan(unpublished: [], published: [live, down, expired], policy: policy, now: now)
        XCTAssertEqual(Set(plan.deletes.compactMap(\.id)), Set([down.id!, expired.id!]))
    }

    func testCreateOperationNeverCarriesExactLocationHeadingOrDevice() throws {
        let s = sighting(ageHours: 30)
        s.plateText = "ABC123"; s.unitNumber = "1234"; s.agencyKey = "US-MA/waltham/police"; s.agencyName = "Waltham PD"
        let op = try CloudKitPublisher.createOperation(for: s)
        let record = op["record"] as! [String: Any]
        let fields = record["fields"] as! [String: Any]
        XCTAssertEqual(record["recordType"] as? String, "Sighting")
        XCTAssertEqual(record["recordName"] as? String, s.id!.uuidString, "deterministic so retries are idempotent")
        XCTAssertEqual(Set(fields.keys), ["capturedAt", "geohash6", "fleetConfidence", "moderationState", "plateText", "unitNumber", "agencyKey", "agencyName"])
        let json = String(decoding: try CloudKitPublisher.modifyBody([op]), as: UTF8.self)
        XCTAssertFalse(json.contains("37.77") || json.contains("-122.41") || json.contains("dev"), "no exact coordinates, heading or device hash")
    }

    func testAgencyFlaggedForReviewIsNotPublishedAsFact() throws {
        let s = sighting(ageHours: 30)
        s.agencyKey = "US-MA/x/police"; s.agencyName = "X PD"; s.agencyNeedsReview = true
        let fields = ((try CloudKitPublisher.createOperation(for: s))["record"] as! [String: Any])["fields"] as! [String: Any]
        XCTAssertNil(fields["agencyKey"]); XCTAssertNil(fields["agencyName"])
        XCTAssertNil(fields["plateText"], "no plate unless the row carries one")
    }

    func testDeleteOperationUsesForceDelete() throws {
        let s = sighting(ageHours: 30, published: true)
        let op = try CloudKitPublisher.deleteOperation(for: s)
        XCTAssertEqual(op["operationType"] as? String, "forceDelete")
    }

    // MARK: signing

    func testSignedMessageShapeAndVerifiableSignature() throws {
        let key = P256.Signing.PrivateKey()
        let body = Data("{\"operations\":[]}".utf8)
        let path = CloudKitPublisher.subpath(container: "iCloud.org.platewatch.platewatch", environment: "development")
        XCTAssertEqual(path, "/database/1/iCloud.org.platewatch.platewatch/development/public/records/modify")
        let date = CloudKitPublisher.isoDate(Date(timeIntervalSince1970: 0))
        XCTAssertEqual(date, "1970-01-01T00:00:00Z")
        let message = CloudKitPublisher.signedMessage(date: date, body: body, subpath: path)
        XCTAssertTrue(message.hasPrefix(date + ":") && message.hasSuffix(":" + path), "<date>:<base64 body hash>:<subpath>")
        let sig = try CloudKitPublisher.signature(date: date, body: body, subpath: path, key: key)
        let der = try XCTUnwrap(Data(base64Encoded: sig))
        let parsed = try P256.Signing.ECDSASignature(derRepresentation: der)
        XCTAssertTrue(key.publicKey.isValidSignature(parsed, for: Data(message.utf8)))
        let headers = CloudKitPublisher.headers(keyID: "k", date: date, signature: sig)
        XCTAssertEqual(headers.first(name: "X-Apple-CloudKit-Request-KeyID"), "k")
        XCTAssertNotNil(headers.first(name: "X-Apple-CloudKit-Request-SignatureV1"))
    }

    func testPerRecordOutcomeInterpretation() {
        XCTAssertTrue(CloudKitPublisher.succeeded(["recordName": "x"], isDelete: false))
        XCTAssertTrue(CloudKitPublisher.succeeded(["serverErrorCode": "CONFLICT"], isDelete: false), "retry after a lost response")
        XCTAssertFalse(CloudKitPublisher.succeeded(["serverErrorCode": "ACCESS_DENIED"], isDelete: false))
        XCTAssertTrue(CloudKitPublisher.succeeded(["serverErrorCode": "NOT_FOUND"], isDelete: true))
        XCTAssertFalse(CloudKitPublisher.succeeded(["serverErrorCode": "ACCESS_DENIED"], isDelete: true))
    }
}
