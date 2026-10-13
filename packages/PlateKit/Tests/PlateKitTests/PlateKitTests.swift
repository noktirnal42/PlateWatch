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

final class GeohashTests: XCTestCase {
    // Reference vectors from geohash.org / public test corpora.
    func testEncodeReferenceVectors() {
        XCTAssertEqual(Geohash.encode(latitude: 57.64911, longitude: 10.40744, precision: 11),
                       "u4pruydqqvj")
        // Austin, TX and Washington, DC — verified against geohash.org.
        XCTAssertEqual(Geohash.encode(latitude: 30.2672, longitude: -97.7431), "9v6kpv")
        XCTAssertEqual(Geohash.encode(latitude: 38.8977, longitude: -77.0365), "dqcjqc")
    }

    func testDecodeRoundTripWithinCell() {
        let hash = Geohash.encode(latitude: 30.2672, longitude: -97.7431)
        let center = Geohash.decodeCenter(hash)!
        // Precision-6 cells are ≤ ~610 m; center error must stay sub-km.
        XCTAssertEqual(center.latitude, 30.2672, accuracy: 0.01)
        XCTAssertEqual(center.longitude, -97.7431, accuracy: 0.01)
    }

    func testGeoBucketFromCoords() {
        let bucket = GeoBucket(latitude: 30.2672, longitude: -97.7431)
        XCTAssertEqual(bucket.geohash6, "9v6kpv")
        XCTAssertNil(bucket.exactLatitude) // exact geo only via fleet-confirm path
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

final class FleetTextPrecisionTests: XCTestCase {
    private func obs(_ text: String) -> SceneTextObservation {
        SceneTextObservation(text: text,
                             boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1),
                             confidence: 0.9)
    }

    func testServiceWordsMatchWholeWordsOnly() {
        XCTAssertNil(SceneTextHeuristics.parse([obs("SYSTEMS")]).serviceClassText)
        XCTAssertNil(SceneTextHeuristics.parse([obs("FIREFOX")]).serviceClassText)
        XCTAssertEqual(SceneTextHeuristics.parse([obs("EMS")]).serviceClassText, "EMS")
        XCTAssertEqual(SceneTextHeuristics.parse([obs("COUNTY SHERIFF'S OFFICE")]).serviceClassText, "SHERIFF")
    }

    func testStrongDoorTextAloneClearsThePersistThresholdWithoutAClassifier() {
        let gate = RedactionGate(config: .standard)
        let markings = SceneTextHeuristics.parse([obs("CITY OF AUSTIN"), obs("POLICE"), obs("UNIT 4421")])
        let c = gate.fleetConfidence(vehicleClassifierFleet: 0, markings: markings,
                                     knownUnitMatch: false, exemptPlateDesign: false)
        XCTAssertEqual(gate.verdict(fleetConfidence: c), .persistAndSync)
    }

    func testBareDecalOrAgencyLineAloneDoesNotPersist() {
        let gate = RedactionGate(config: .standard)
        for lines in [["POLICE"], ["CITY OF AUSTIN"], ["POLICE", "UNIT 12"]] {
            let markings = SceneTextHeuristics.parse(lines.map(obs))
            let c = gate.fleetConfidence(vehicleClassifierFleet: 0, markings: markings,
                                         knownUnitMatch: false, exemptPlateDesign: false)
            XCTAssertNotEqual(gate.verdict(fleetConfidence: c), .persistAndSync, "\(lines)")
        }
    }
}

final class FleetTextRobustnessTests: XCTestCase {
    private func obs(_ text: String) -> SceneTextObservation {
        SceneTextObservation(text: text, boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1), confidence: 0.9)
    }
    func testOneGlyphOCRErrorsStillMatchLongKeywords() {
        XCTAssertEqual(SceneTextHeuristics.parse([obs("POLIGE")]).serviceClassText, "POLICE")
        XCTAssertEqual(SceneTextHeuristics.parse([obs("SHERIFE")]).serviceClassText, "SHERIFF")
    }
    func testShortKeywordsAndUnrelatedWordsStayExact() {
        XCTAssertNil(SceneTextHeuristics.parse([obs("FIRM")]).serviceClassText)
        XCTAssertNil(SceneTextHeuristics.parse([obs("POLISH SAUSAGE")]).serviceClassText)
        XCTAssertNil(SceneTextHeuristics.parse([obs("PELICAN")]).serviceClassText)
    }
    func testPostalAndSchoolBusKeywords() {
        XCTAssertEqual(SceneTextHeuristics.parse([obs("UNITED STATES POSTAL SERVICE")]).serviceClassText, "POSTAL SERVICE")
        XCTAssertEqual(SceneTextHeuristics.parse([obs("SCHOOL BUS")]).serviceClassText, "SCHOOL BUS")
    }
}

final class StackedAndOwnedTextTests: XCTestCase {
    private func obs(_ text: String, x: Double = 0.1, y: Double = 0.5) -> SceneTextObservation {
        SceneTextObservation(text: text, boundingBox: .init(x: x, y: y, width: 0.2, height: 0.05), confidence: 0.9)
    }

    func testStackedLinesFormAMultiWordKeyword() {
        // "HIGHWAY" above "PATROL" (Oklahoma): read as two lines, one keyword.
        let m = SceneTextHeuristics.parse([obs("HIGHWAY", y: 0.52), obs("PATROL", y: 0.46), obs("OKLAHOMA", y: 0.40)])
        XCTAssertEqual(m.serviceClassText, "HIGHWAY PATROL")
        XCTAssertTrue(m.hasFleetKeyword)
    }

    func testFarApartWordsDoNotJoin() {
        let m = SceneTextHeuristics.parse([obs("PUBLIC", x: 0.05, y: 0.9), obs("WORKS", x: 0.7, y: 0.1)])
        XCTAssertNil(m.serviceClassText)
    }

    func testOwnerQualifiedAgencyClearsTheGateAlone() {
        let gate = RedactionGate(config: .standard)
        for lines in [["SEATTLE FIRE DEPARTMENT"], ["WYOMING HIGHWAY PATROL", "STATE TROOPER"], ["City of Pittsburgh", "PUBLIC WORKS"]] {
            let m = SceneTextHeuristics.parse(lines.map { obs($0) })
            let c = gate.fleetConfidence(vehicleClassifierFleet: 0, markings: m, knownUnitMatch: false, exemptPlateDesign: false)
            XCTAssertTrue(m.agencyIsOwnerQualified, "\(lines)")
            XCTAssertEqual(gate.verdict(fleetConfidence: c), .persistAndSync, "\(lines) conf=\(c)")
        }
    }

    func testServiceWordsWithoutAnOwnerStillNeedMoreEvidence() {
        let gate = RedactionGate(config: .standard)
        for lines in [["POLICE"], ["FIRE RESCUE"], ["ABOUT US", "FIRE"]] {
            let m = SceneTextHeuristics.parse(lines.map { obs($0) })
            let c = gate.fleetConfidence(vehicleClassifierFleet: 0, markings: m, knownUnitMatch: false, exemptPlateDesign: false)
            XCTAssertNotEqual(gate.verdict(fleetConfidence: c), .persistAndSync, "\(lines) conf=\(c)")
        }
    }
}

final class PlausiblePlateTests: XCTestCase {
    func testRealPlateShapesAreAccepted() {
        for p in ["1ABC234", "K398HN", "JL923", "7ABC123", "FDB574", "PZ3122G", "ABC1234"] {
            XCTAssertTrue(Plate.isPlausibleReading(p), p)
        }
    }
    func testWordsSlogansAndAssetIdsAreRejected() {
        for p in ["NEWYORK", "GEORGIA", "COMPANY7", "DRIVEU", "FALCK", "0325775", "2116585", "1623", "T10", "ROUTE5076", "ABCDEFGHI1"] {
            XCTAssertFalse(Plate.isPlausibleReading(p), p)
        }
    }
}

final class OfficialPlateTests: XCTestCase {
    func testMassachusettsPolicePlateLineParsesToItsRegistration() {
        // Exactly what Vision returned for the Waltham Police photo.
        let r = Plate.officialRegistration(from: "POLICE D756")
        XCTAssertEqual(r?.registration, "D756")
        XCTAssertEqual(r?.design, "government-official")
        XCTAssertEqual(Plate.officialRegistration(from: "POLICE D756 OFFICIAL")?.registration, "D756")
    }
    func testOrdinaryTextIsNotAnOfficialPlate() {
        for t in ["WALTHAM", "D756", "POLICE", "OFFICIAL", "ABC1234", "POLICE DEPARTMENT", "POLICE INTERCEPTOR"] {
            XCTAssertNil(Plate.officialRegistration(from: t), t)
        }
    }
    func testOfficialPlateIsDecisiveForTheGate() {
        let gate = RedactionGate(config: .standard)
        let c = gate.fleetConfidence(vehicleClassifierFleet: 0, markings: FleetMarkings(),
                                     knownUnitMatch: false, exemptPlateDesign: true, officialPlate: true)
        XCTAssertEqual(gate.verdict(fleetConfidence: c), .persistAndSync)
        let plate = Plate(text: "D756", plateDesign: "government-official", confidence: 0.9)
        XCTAssertTrue(plate.isOfficialPlate)
        XCTAssertTrue(plate.exemptDesignHint)
    }
}

final class JurisdictionTests: XCTestCase {
    func testOfficialPlateLineLogsItsIssuingRegion() {
        // Plate crop joined lines: state header + registration.
        let r = Plate.officialRegistration(from: "Massachusetts POLICE D756 OFFICIAL")
        XCTAssertEqual(r?.registration, "D756")
        XCTAssertEqual(r?.jurisdiction, "MASSACHUSETTS")
        XCTAssertEqual(Plate.issuingRegion(forStateName: "Massachusetts"), "US-MA")
        XCTAssertEqual(Plate.issuingRegion(forStateName: "new york"), "US-NY")
        XCTAssertNil(Plate.issuingRegion(forStateName: "Ontario"))
    }
}

final class FuzzyPhraseTests: XCTestCase {
    private func obs(_ t: String) -> SceneTextObservation {
        SceneTextObservation(text: t, boundingBox: .init(x: 0, y: 0, width: 0.2, height: 0.05), confidence: 0.9)
    }
    func testGarbledHighwayPatrolStillMatches() {
        XCTAssertEqual(SceneTextHeuristics.parse([obs("LIGHWAY PATROL")]).serviceClassText, "HIGHWAY PATROL")
        XCTAssertEqual(SceneTextHeuristics.parse([obs("AIGHWAY PATROL.")]).serviceClassText, "HIGHWAY PATROL")
    }
    func testTwoGarbledWordsDoNotFormAKeyword() {
        XCTAssertNil(SceneTextHeuristics.parse([obs("LIGHWAY PATROI")]).serviceClassText)
        XCTAssertNil(SceneTextHeuristics.parse([obs("HIGHLY PATRONS")]).serviceClassText)
    }
}

final class GroundedMarkingsTests: XCTestCase {
    private func obs(_ t: String) -> SceneTextObservation {
        SceneTextObservation(text: t, boundingBox: .init(x: 0, y: 0, width: 0.2, height: 0.05), confidence: 0.9)
    }
    /// Seen in the app: the on-device LLM turned "HYBRID AND…" badge text into a fleet service.
    func testHallucinatedServiceIsDroppedAndCannotRaiseTheGate() {
        let lines = [obs("HYBRID AND"), obs("Ford")]
        let claim = FleetMarkings(agencyText: "Hybridand", unitNumber: nil, serviceClassText: "Hybridand", hasFleetKeyword: true)
        let g = SceneTextHeuristics.grounded(claim, in: lines, fallback: SceneTextHeuristics.parse(lines))
        XCTAssertNil(g.serviceClassText)
        XCTAssertFalse(g.hasFleetKeyword, "an invented keyword must not become a fleet signal")
        let gate = RedactionGate(config: .standard)
        let c = gate.fleetConfidence(vehicleClassifierFleet: 0, markings: g, knownUnitMatch: false, exemptPlateDesign: false)
        XCTAssertEqual(c, 0, accuracy: 0.001)
    }
    func testSupportedClaimsSurviveAndAreNormalised() {
        let lines = [obs("AUSTIN POLICE DEPT"), obs("UNIT 4421")]
        let claim = FleetMarkings(agencyText: "Austin Police Department", unitNumber: "4421", serviceClassText: "Police", hasFleetKeyword: true)
        let g = SceneTextHeuristics.grounded(claim, in: lines, fallback: SceneTextHeuristics.parse(lines))
        XCTAssertEqual(g.serviceClassText, "POLICE")
        XCTAssertEqual(g.unitNumber, "4421")
        XCTAssertTrue(g.hasFleetKeyword)
    }
    func testAnInventedUnitNumberIsRejected() {
        let lines = [obs("CITY POLICE")]
        let claim = FleetMarkings(unitNumber: "9999", serviceClassText: "POLICE", hasFleetKeyword: true)
        XCTAssertNil(SceneTextHeuristics.grounded(claim, in: lines, fallback: SceneTextHeuristics.parse(lines)).unitNumber)
    }
}
