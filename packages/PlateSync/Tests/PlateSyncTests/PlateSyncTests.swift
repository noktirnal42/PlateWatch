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
