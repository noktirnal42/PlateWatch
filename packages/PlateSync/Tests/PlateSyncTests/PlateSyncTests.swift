import XCTest
import Foundation
@testable import PlateSync
import PlateKit

final class OutboxTests: XCTestCase {
    func testIdempotencyKeyStable() {
        let dto = SightingSubmissionDTO(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            geohash6: "9v6kn7", deviceIDHash: "aa", fleetConfidence: 0.9,
            plate: PlateDTO(text: "1ABC234"),
            vehicle: VehicleObservationDTO(vehicleClass: "patrol", classConfidence: 0.8))
        XCTAssertEqual(OutboxDrainer.idempotencyKey(for: dto),
                       OutboxDrainer.idempotencyKey(for: dto))
    }

    func testIdempotencyKeyChangesWithContent() {
        let base = SightingSubmissionDTO(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            geohash6: "9v6kn7", deviceIDHash: "aa", fleetConfidence: 0.9,
            plate: PlateDTO(text: "1ABC234"),
            vehicle: VehicleObservationDTO(vehicleClass: "patrol", classConfidence: 0.8))
        var changed = base
        changed.plate = PlateDTO(text: "1ABC235")
        XCTAssertNotEqual(OutboxDrainer.idempotencyKey(for: base),
                          OutboxDrainer.idempotencyKey(for: changed))
    }

    func testBackendProtocolSurface() async {
        // Compile-time contract: any SyncBackend can be used existentially.
        let backend: any SyncBackend = RESTBackend(baseURL: URL(string: "http://localhost:8080")!)
        _ = backend
    }
}
