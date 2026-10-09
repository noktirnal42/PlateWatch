import XCTest
@testable import App
import XCTVapor
import Vapor

final class ExportRendererTests: XCTestCase {
    private let rows = [
        ExportRenderer.Row(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
                           capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
                           geohash6: "9v6kpv", plateText: "1ABC234",
                           unitNumber: "4421", fleetConfidence: 0.92),
        ExportRenderer.Row(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
                           capturedAt: Date(timeIntervalSince1970: 1_700_100_000),
                           geohash6: "dqcjqc", plateText: nil,
                           unitNumber: nil, fleetConfidence: 0.8),
    ]

    func testCSVShape() {
        let csv = ExportRenderer.csv(rows)
        let lines = csv.split(separator: "\n")
        XCTAssertEqual(lines.count, 3) // header + 2 rows
        XCTAssertTrue(lines[0].hasPrefix("id,captured_at"))
        XCTAssertTrue(lines[1].contains("1ABC234"))
        XCTAssertTrue(lines[1].contains("4421"))
    }

    func testGeoJSONStructureAndBucketing() throws {
        let json = ExportRenderer.geoJSON(rows)
        // Parse it properly — string sniffing is not a test.
        let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, "FeatureCollection")
        let features = object?["features"] as? [[String: Any]]
        XCTAssertEqual(features?.count, 2)
        // Bucket centers, not exact coordinates, must be exported.
        let center = ExportRenderer.geohashCenter("9v6kpv")!
        XCTAssertEqual(center.lat, 30.2672, accuracy: 0.01)
        XCTAssertEqual(center.lon, -97.7431, accuracy: 0.01)
    }

    func testBadGeohashDropsFeature() {
        let bad = [ExportRenderer.Row(id: UUID(), capturedAt: Date(), geohash6: "!!!",
                                      plateText: "X", unitNumber: nil, fleetConfidence: 1)]
        XCTAssertTrue(ExportRenderer.geoJSON(bad).contains(#""features":[]"#))
    }
}

final class WireProtocolTests: XCTestCase {
    /// The fields a client sends must survive the wire decode on the server
    /// — QA regression: unit numbers from markings were silently dropped
    /// pre-fix (caught by live API test, 2026-10-09).
    func testSubmissionDTOCarriesUnitNumber() throws {
        let json = """
        {"capturedAt":"2026-10-09T04:00:00Z","geohash6":"9v6kpv",
         "deviceIDHash":"dev-qa-1","fleetConfidence":0.85,
         "plate":{"text":"1ABC234","issuingRegion":"US-CA","country":"US","plateDesign":"US-CA-exempt","confidence":0.9},
         "vehicle":{"vehicleClass":"patrol","classConfidence":0.8},
         "markings":{"agencyText":"AUSTIN POLICE","unitNumber":"4421"}}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(SightingSubmissionDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.markings?.unitNumber, "4421")
        XCTAssertEqual(dto.plate?.text, "1ABC234")
        XCTAssertEqual(dto.plate?.plateDesign, "US-CA-exempt")
    }
}

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
