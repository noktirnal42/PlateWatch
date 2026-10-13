import XCTest
import Foundation
@testable import PlateSync
import PlateKit

final class OutboxTests: XCTestCase {
    private func dto(plateText: String = "1ABC234") -> SightingSubmissionDTO {
        SightingSubmissionDTO(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            geohash6: "9v6kn7", deviceIDHash: "aa", fleetConfidence: 0.9,
            plate: PlateDTO(text: plateText),
            vehicle: VehicleObservationDTO(vehicleClass: "patrol", classConfidence: 0.8))
    }

    func testIdempotencyKeyStable() {
        XCTAssertEqual(OutboxDrainer.idempotencyKey(for: dto()),
                       OutboxDrainer.idempotencyKey(for: dto()))
    }

    /// The key must be identical across processes and devices — the old
    /// `Hasher`-based key was re-seeded on every launch, so outbox rows
    /// drained after a restart arrived at the server as brand-new
    /// submissions and idempotent replays stopped deduping. This golden
    /// value pins the SHA-256 serialization: 8-byte big-endian epoch
    /// bitPattern, then each field UTF-8 + NUL separator
    /// (geohash6, plate.text, vehicleClass, cropHashSHA256).
    func testIdempotencyKeyDeterministicGoldenValue() {
        XCTAssertEqual(OutboxDrainer.idempotencyKey(for: dto()),
                       "dbd80a5de3da429e920349767a3f946b")
    }

    func testIdempotencyKeyChangesWithContent() {
        var changed = dto()
        changed.plate = PlateDTO(text: "1ABC235")
        XCTAssertNotEqual(OutboxDrainer.idempotencyKey(for: dto()),
                          OutboxDrainer.idempotencyKey(for: changed))
    }

    func testIdempotencyKeyChangesWithMissingFields() {
        var noCrop = dto()
        noCrop.cropHashSHA256 = "cafe"
        XCTAssertNotEqual(OutboxDrainer.idempotencyKey(for: dto()),
                          OutboxDrainer.idempotencyKey(for: noCrop))
    }

    func testBackendProtocolSurface() async {
        // Compile-time contract: any SyncBackend can be used existentially.
        let backend: any SyncBackend = RESTBackend(baseURL: URL(string: "http://localhost:8080")!)
        _ = backend
    }
}

final class HeatmapAggregatorTests: XCTestCase {
    private func sighting(_ cell: String, daysAgo: Double, now: Date) -> PublicSightingDTO {
        PublicSightingDTO(id: UUID(), capturedAt: now.addingTimeInterval(-daysAgo * 86_400),
                          geohash6: cell, fleetConfidence: 0.9)
    }

    func testCellsAndDaysUnderKAreWithheld() {
        let now = Date()
        var rows: [PublicSightingDTO] = []
        for _ in 0..<5 { rows.append(sighting("9q8yyk", daysAgo: 1, now: now)) }  // meets k
        for _ in 0..<4 { rows.append(sighting("9q8yym", daysAgo: 2, now: now)) }  // under k
        let agg = HeatmapAggregator.aggregate(rows, k: 5, since: now.addingTimeInterval(-10 * 86_400), until: now)
        XCTAssertEqual(agg.cells.map(\.geohash6), ["9q8yyk"])
        XCTAssertEqual(agg.cells.first?.count, 5)
        XCTAssertEqual(agg.withheldCells, 1)
        XCTAssertEqual(agg.timeline.count, 1)
        XCTAssertEqual(agg.withheldDays, 1)
    }

    func testOutsideWindowIsExcluded() {
        let now = Date()
        let rows = (0..<6).map { _ in sighting("9q8yyk", daysAgo: 40, now: now) }
        let agg = HeatmapAggregator.aggregate(rows, k: 5, since: now.addingTimeInterval(-30 * 86_400), until: now)
        XCTAssertTrue(agg.cells.isEmpty)
        XCTAssertEqual(agg.withheldCells, 0)
    }
}

final class CloudKitPrivacyTests: XCTestCase {
    private func dto(confidence: Double, markings: FleetMarkingsDTO?) -> SightingSubmissionDTO {
        SightingSubmissionDTO(
            capturedAt: Date(), geohash6: "9v6kn7", deviceIDHash: "aa", fleetConfidence: confidence,
            plate: PlateDTO(text: "1ABC234"),
            vehicle: VehicleObservationDTO(vehicleClass: "patrol", classConfidence: 0.8),
            markings: markings)
    }

    /// Uploads are creator-readable only, but the plate still stays on the
    /// device unless the same rule that publishes it on the REST server holds.
    func testPlateOnlyLeavesTheDeviceWhenFleetConfirmed() {
        let marked = FleetMarkingsDTO(agencyText: "CITY OF AUSTIN", unitNumber: "4421", serviceClassText: "POLICE")
        XCTAssertTrue(CloudKitBackend.mayUploadPlate(dto(confidence: 0.85, markings: marked)))
        XCTAssertFalse(CloudKitBackend.mayUploadPlate(dto(confidence: 0.6, markings: marked)))
        XCTAssertFalse(CloudKitBackend.mayUploadPlate(dto(confidence: 0.95, markings: nil)))
    }

    func testRecordTypesAreTheDocumentedOnes() {
        XCTAssertEqual(CloudKitBackend.RecordType.submission, "SightingSubmission")
        XCTAssertEqual(CloudKitBackend.RecordType.sighting, "Sighting")
    }
}
