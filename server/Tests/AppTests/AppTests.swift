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

    /// QA regression: the server DTO used flat `hasLightBar/…` booleans
    /// while PlateKit nests them under `attributes` — classifier output was
    /// silently dropped on ingest (2026-10-11).
    func testSubmissionDTOCarriesNestedAttributes() throws {
        let json = """
        {"capturedAt":"2026-10-09T04:00:00Z","geohash6":"9v6kpv",
         "deviceIDHash":"dev-qa-1","fleetConfidence":0.85,
         "vehicle":{"vehicleClass":"patrol","classConfidence":0.8,
           "attributes":{"make":"Ford","model":"Explorer","color":"black",
             "hasLightBar":true,"hasFleetDecals":true}}}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(SightingSubmissionDTO.self, from: Data(json.utf8))
        XCTAssertEqual(dto.vehicle.attributes?.make, "Ford")
        XCTAssertEqual(dto.vehicle.attributes?.color, "black")
        XCTAssertEqual(dto.vehicle.attributes?.hasLightBar, true)
        XCTAssertEqual(dto.vehicle.attributes?.hasFleetDecals, true)
        XCTAssertNil(dto.vehicle.attributes?.hasPushBar)
    }

    func testVehicleAttributesDTOMatchesPlateKitShape() throws {
        // Encode with PlateKit's exact JSON shape (Sendable Codable struct)
        // and decode with the server DTO.
        let attributesJSON = """
        {"make":"Ford","model":null,"color":"white","bodyType":null,
         "hasLightBar":true,"hasPushBar":false,"hasFleetDecals":true}
        """
        let dto = try JSONDecoder().decode(VehicleAttributesDTO.self,
                                           from: Data(attributesJSON.utf8))
        XCTAssertEqual(dto.make, "Ford")
        XCTAssertEqual(dto.hasPushBar, false)
        XCTAssertEqual(dto.hasFleetDecals, true)
    }
}

final class SightingCursorTests: XCTestCase {
    func testTokenRoundTrip() throws {
        let date = Date(timeIntervalSince1970: 1_760_000_000.25)
        let cursor = SightingCursor(timestamp: date,
                                    lastID: UUID(uuidString: "ABCDEF01-2345-6789-ABCD-EF0123456789")!)
        let parsed = try XCTUnwrap(SightingCursor.parse(cursor.token))
        XCTAssertEqual(parsed, cursor)
    }

    func testParseRejectsGarbage() {
        XCTAssertNil(SightingCursor.parse(nil))
        XCTAssertNil(SightingCursor.parse(""))
        XCTAssertNil(SightingCursor.parse("not-a-cursor"))
        XCTAssertNil(SightingCursor.parse("2026-10-09T04:00:00Z|not-a-uuid"))
    }

    func testParseAcceptsLegacySinceDate() throws {
        // Old-style bare-timestamp tokens keep working as resume points
        // pinned to that second (the ID tiebreaker is unknown).
        let parsed = try XCTUnwrap(SightingCursor.parse(
            SightingCursor.plainFormatter.string(from: Date(timeIntervalSince1970: 0)) + "|00000000-0000-0000-0000-000000000000"))
        XCTAssertEqual(parsed.timestamp.timeIntervalSince1970, 0, accuracy: 0.001)
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

/// Identity (agency key, plate jurisdiction) rides on the submission and the public feed — but a
/// flagged identity is never published as fact, and the registration never rides on the identity.
final class SightingIdentityTests: XCTestCase {
    private let payload = """
    {"capturedAt":"2026-10-13T20:00:00Z","geohash6":"drt2yz","deviceIDHash":"aa","fleetConfidence":0.9,
     "vehicle":{"vehicleClass":"patrol","classConfidence":0.8},
     "identity":{"agency":{"name":"Waltham Police Department","service":"Police","place":"Waltham","state":"MA",
        "agencyKey":"US-MA/waltham/police","confidence":0.93,"needsReview":false,"isInferred":true,
        "vehicleClass":"patrol","alternatives":[]},
       "plate":{"registration":"D756","state":"MA","stateName":"Massachusetts","confidence":0.9},
       "unitNumbers":[],"vehicle":{"traits":[]},"evidence":[],"consistency":[]}}
    """

    func testSubmissionDecodesIdentityFromPlateKitJSON() throws {
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(SightingSubmissionDTO.self, from: Data(payload.utf8))
        XCTAssertEqual(dto.identity?.agency?.agencyKey, "US-MA/waltham/police")
        XCTAssertEqual(dto.identity?.agency?.needsReview, false)
        XCTAssertEqual(dto.identity?.plate?.state, "MA")
    }

    func testOldClientsWithoutIdentityStillDecode() throws {
        let legacy = """
        {"capturedAt":"2026-10-13T20:00:00Z","geohash6":"drt2yz","deviceIDHash":"aa","fleetConfidence":0.9,
         "vehicle":{"vehicleClass":"patrol","classConfidence":0.8}}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let dto = try decoder.decode(SightingSubmissionDTO.self, from: Data(legacy.utf8))
        XCTAssertNil(dto.identity)
    }

    func testCSVAndGeoJSONCarryTheAgency() throws {
        let row = ExportRenderer.Row(id: UUID(), capturedAt: Date(timeIntervalSince1970: 1_700_000_000), geohash6: "drt2yz",
                                     plateText: nil, unitNumber: "4421", fleetConfidence: 0.9,
                                     agencyKey: "US-MA/waltham/police", agencyName: "Waltham Police Department")
        let csv = ExportRenderer.csv([row])
        XCTAssertTrue(csv.hasPrefix("id,captured_at,geohash6,plate_text,unit_number,fleet_confidence,agency_key,agency_name"))
        XCTAssertTrue(csv.contains("US-MA/waltham/police,Waltham Police Department"))
        let json = ExportRenderer.geoJSON([row])
        let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
        let props = ((obj?["features"] as? [[String: Any]])?.first?["properties"]) as? [String: Any]
        XCTAssertEqual(props?["agency_key"] as? String, "US-MA/waltham/police")
    }
}
