import XCTest
@testable import PlateKit

final class PlateNormalizationTests: XCTestCase {
    func testNormalizeStripsDecorations() {
        XCTAssertEqual(Plate.normalize("abc-1234"), "ABC1234")
        XCTAssertEqual(Plate.normalize("  7 xvz 22 "), "7XVZ22")
        XCTAssertEqual(Plate.normalize("ABC·123"), "ABC123")
    }

    func testConfidenceClamped() {
        let p = Plate(text: "ABC123", confidence: 4.2)
        XCTAssertEqual(p.confidence, 1.0)
    }

    func testExemptDesignHint() {
        XCTAssertTrue(Plate(text: "123456", plateDesign: "US-CA-exempt").exemptDesignHint)
        XCTAssertFalse(Plate(text: "ABC1234", plateDesign: "US-CA-standard").exemptDesignHint)
        XCTAssertFalse(Plate(text: "ABC1234").exemptDesignHint)
    }
}

final class PlatePatternTests: XCTestCase {
    func testCaliforniaStandard() {
        let ranked = PlatePatternCatalog.rank("1ABC234")
        XCTAssertTrue(ranked.contains(where: { $0.region == "US-CA" && $0.pattern == "standard" }))
    }

    func testUSGovernmentPattern() {
        let ranked = PlatePatternCatalog.rank("US12345")
        XCTAssertTrue(ranked.contains(where: { $0.pattern == "us-government" }))
    }

    func testRegionFilter() {
        let ranked = PlatePatternCatalog.rank("ABC1234", regions: ["US-TX"])
        XCTAssertTrue(ranked.allSatisfy { $0.region == "US-TX" })
    }
}

final class RedactionGateTests: XCTestCase {
    let gate = RedactionGate()

    func testUnmarkedPrivateVehicleDiscarded() {
        let c = gate.fleetConfidence(vehicleClassifierFleet: 0.1,
                                     hasFleetMarkings: false,
                                     knownUnitMatch: false,
                                     exemptPlateDesign: false)
        XCTAssertEqual(gate.verdict(fleetConfidence: c), .discard)
    }

    func testMarkedPatrolCarPersists() {
        let c = gate.fleetConfidence(vehicleClassifierFleet: 0.8,
                                     hasFleetMarkings: true,
                                     knownUnitMatch: true,
                                     exemptPlateDesign: false)
        XCTAssertEqual(gate.verdict(fleetConfidence: c), .persistAndSync)
    }

    func testAmbiguousStaysLocal() {
        // Classifier thinks maybe fleet (0.5 → 0.225), nothing else.
        let c = gate.fleetConfidence(vehicleClassifierFleet: 0.5,
                                     hasFleetMarkings: false,
                                     knownUnitMatch: false,
                                     exemptPlateDesign: false)
        XCTAssertEqual(gate.verdict(fleetConfidence: c), .keepLocalOnly)
    }

    func testStrictConfigRaisesBar() {
        let strict = RedactionGate(config: .strict)
        let c = strict.fleetConfidence(vehicleClassifierFleet: 0.8,
                                       hasFleetMarkings: true,
                                       knownUnitMatch: false,
                                       exemptPlateDesign: false)
        // 0.36+0.30 = 0.66 < 0.8 strict threshold → local only.
        XCTAssertEqual(strict.verdict(fleetConfidence: c), .keepLocalOnly)
    }

    func testGateSanitizesFrame() {
        let frame = DetectionFrame(
            timestamp: Date(timeIntervalSince1970: 0),
            imageSize: CGSize(width: 1920, height: 1080),
            vehicles: [
                VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 0.2, height: 0.2),
                                   vehicleClass: .patrol),
                VehicleObservation(boundingBox: .init(x: 0.5, y: 0.5, width: 0.2, height: 0.2),
                                   vehicleClass: .privateVehicle),
            ]
        )
        let (verdicts, sanitized) = gate.gate(frame, confidences: [
            frame.vehicles[0].id: 0.9,
            frame.vehicles[1].id: 0.1,
        ])
        XCTAssertEqual(verdicts[frame.vehicles[0].id], .persistAndSync)
        XCTAssertEqual(verdicts[frame.vehicles[1].id], .discard)
        XCTAssertEqual(sanitized.vehicles.count, 1)
        XCTAssertEqual(sanitized.vehicles.first?.vehicleClass, .patrol)
    }
}

final class SceneTextHeuristicsTests: XCTestCase {
    private func obs(_ text: String) -> SceneTextObservation {
        SceneTextObservation(text: text,
                             boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1),
                             confidence: 0.9)
    }

    func testParsesAgencyAndUnit() {
        let m = SceneTextHeuristics.parse([obs("CITY OF AUSTIN"), obs("POLICE"), obs("UNIT 4421")])
        XCTAssertTrue(m.hasFleetKeyword)
        XCTAssertEqual(m.serviceClassText, "POLICE")
        XCTAssertEqual(m.unitNumber, "4421")
        XCTAssertEqual(m.agencyText, "CITY OF AUSTIN")
    }

    func testFireEngineAssetStyle() {
        let m = SceneTextHeuristics.parse([obs("AUSTIN FIRE DEPT"), obs("ENGINE 42")])
        XCTAssertTrue(m.hasFleetKeyword)
        XCTAssertEqual(m.unitNumber, "42")
    }

    func testCivilianTextIgnored() {
        let m = SceneTextHeuristics.parse([obs("BABY ON BOARD"), obs("HONK IF YOU LOVE TACOS")])
        XCTAssertFalse(m.hasFleetKeyword)
        XCTAssertNil(m.unitNumber)
    }

    func testBareRoofNumber() {
        let m = SceneTextHeuristics.parse([obs("POLICE"), obs("4421")])
        XCTAssertEqual(m.unitNumber, "4421")
    }
}

final class DTOTests: XCTestCase {
    func testPlateDTORoundTrip() throws {
        let dto = PlateDTO(Plate(text: " abc-123 ", issuingRegion: "US-TX", confidence: 0.9))
        let data = try JSONEncoder().encode(dto)
        let back = try JSONDecoder().decode(PlateDTO.self, from: data)
        XCTAssertEqual(back.text, "ABC123")
        XCTAssertEqual(back.issuingRegion, "US-TX")
    }

    func testSightingSubmissionDTORoundTrip() throws {
        let dto = SightingSubmissionDTO(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            geohash6: "9v6kn7",
            deviceIDHash: "deadbeef",
            fleetConfidence: 0.92,
            plate: PlateDTO(text: "1ABC234", issuingRegion: "US-CA", confidence: 0.88),
            vehicle: VehicleObservationDTO(vehicleClass: "patrol", classConfidence: 0.77,
                                           attributes: .init(hasLightBar: true)),
            markings: FleetMarkingsDTO(agencyText: "LAPD", unitNumber: "88234")
        )
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
        let back = try dec.decode(SightingSubmissionDTO.self, from: try enc.encode(dto))
        XCTAssertEqual(back.plate?.text, "1ABC234")
        XCTAssertEqual(back.vehicle.attributes?.hasLightBar, true)
        XCTAssertEqual(back.markings?.unitNumber, "88234")
    }
}

final class WatchlistTests: XCTestCase {
    func testPlateMatch() {
        let entry = WatchlistEntry(plateText: "abc-123")
        XCTAssertTrue(entry.matches(plate: Plate(text: "ABC123"), featureAnchor: nil))
        XCTAssertFalse(entry.matches(plate: Plate(text: "ABC124"), featureAnchor: nil))
    }

    func testFeatureAnchorMatch() {
        let entry = WatchlistEntry(featurePrintAnchor: "0a1b2c")
        XCTAssertTrue(entry.matches(plate: nil, featureAnchor: "0a1b2c"))
    }
}
