import XCTest
@testable import App
import XCTVapor
import Vapor

final class RedactionGateServiceTests: XCTestCase {
    private func dto(fleetConfidence: Double,
                     agencyText: String? = nil,
                     unitNumber: String? = nil,
                     plateDesign: String? = nil) -> SightingSubmissionDTO {
        SightingSubmissionDTO(
            capturedAt: Date(), geohash6: "9v6kn7",
            deviceIDHash: "abc", fleetConfidence: fleetConfidence,
            plate: plateDesign.map { PlateDTO(text: "X", issuingRegion: "US-CA",
                                              country: "US", plateDesign: $0,
                                              confidence: 0.9) },
            vehicle: VehicleObservationDTO(vehicleClass: "patrol", classConfidence: 0.9),
            markings: (agencyText != nil || unitNumber != nil)
                ? FleetMarkingsDTO(agencyText: agencyText, unitNumber: unitNumber)
                : nil)
    }

    func testBelowFloorRejected() {
        let out = RedactionGateService.evaluate(dto(fleetConfidence: 0.05))
        XCTAssertEqual(out.state, .rejected)
        XCTAssertFalse(out.exactGeoAllowed)
    }

    func testMarkedAgencyConfirmed() {
        let out = RedactionGateService.evaluate(
            dto(fleetConfidence: 0.85, agencyText: "AUSTIN POLICE", unitNumber: "4421"))
        XCTAssertEqual(out.state, .fleetConfirmed)
        XCTAssertTrue(out.exactGeoAllowed)
    }

    func testUnmarkedHighConfidencePendingOnly() {
        let out = RedactionGateService.evaluate(dto(fleetConfidence: 0.85))
        XCTAssertEqual(out.state, .pending)
        XCTAssertFalse(out.exactGeoAllowed)
    }

    func testExemptPlatePlusConfidenceConfirmed() {
        let out = RedactionGateService.evaluate(
            dto(fleetConfidence: 0.82, plateDesign: "US-CA-exempt"))
        XCTAssertEqual(out.state, .fleetConfirmed)
    }
}
