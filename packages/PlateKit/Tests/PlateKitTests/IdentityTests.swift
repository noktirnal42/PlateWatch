import XCTest
@testable import PlateKit

final class GazetteerTests: XCTestCase {
    func testBundledGazetteerLoadsAndKnowsWaltham() {
        let g = Gazetteer.shared
        XCTAssertGreaterThan(g.count, 50_000)
        let waltham = g.resolve("Waltham", state: "MA")
        XCTAssertEqual(waltham.first?.strength, .exact)
        XCTAssertEqual(waltham.first?.place.name, "Waltham")
        XCTAssertEqual(waltham.first?.place.kind, .city)
    }
    func testFragmentIsAmbiguousBetweenRealTowns() {
        let names = Gazetteer.shared.resolve("THAM", state: "MA").map(\.place.name)
        XCTAssertTrue(names.contains("Waltham"), "\(names)")
        XCTAssertTrue(names.contains("Chatham"), "\(names)")
    }
    func testOneOCRErrorStillFindsThePlace() {
        let m = Gazetteer.shared.resolve("WALTHAN", state: "MA")
        XCTAssertEqual(m.first?.place.name, "Waltham")
        XCTAssertEqual(m.first?.strength, .fuzzy)
    }
    func testGovernmentBeatsCDPOfTheSameName() {
        let m = Gazetteer.shared.resolve("Chatham", state: "MA").filter { $0.place.name == "Chatham" }
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(m.first?.place.kind, .town)
    }
}

final class IdentityResolverTests: XCTestCase {
    private func text(_ s: String) -> SceneTextObservation {
        SceneTextObservation(text: s, boundingBox: .init(x: 0.1, y: 0.4, width: 0.3, height: 0.05), confidence: 0.9)
    }
    private func massPolicePlate() -> PlateObservation {
        PlateObservation(boundingBox: .init(x: 0.4, y: 0.6, width: 0.2, height: 0.1),
                         candidates: [Plate(text: "D756", issuingRegion: "US-MA", plateDesign: "government-official",
                                            confidence: 0.9, officialWords: ["POLICE", "OFFICIAL"])])
    }
    private let resolver = IdentityResolver()

    /// The motivating case: WALTHAM (tailgate) + POLICE (plate) + Massachusetts (plate header).
    func testWalthamPoliceFromTailgatePlusMassachusettsPlate() throws {
        let id = resolver.resolve(sceneText: [text("WALTHAM")], plates: [massPolicePlate()],
                                  vehicleClass: .patrol, markings: FleetMarkings())
        let agency = try XCTUnwrap(id.agency)
        XCTAssertEqual(agency.name, "Waltham Police Department")
        XCTAssertEqual(agency.state, "MA")
        XCTAssertEqual(agency.place, "Waltham")
        XCTAssertEqual(agency.agencyKey, "US-MA/waltham/police")
        XCTAssertGreaterThan(agency.confidence, 0.9)
        XCTAssertFalse(agency.needsReview)
        XCTAssertTrue(agency.isInferred)
        XCTAssertNotNil(agency.citation, "gazetteer canonicalisation must carry a citation")
        XCTAssertEqual(id.plate?.registration, "D756")
        XCTAssertEqual(id.plate?.state, "MA")
        XCTAssertEqual(id.plate?.stateName, "Massachusetts")
        XCTAssertTrue(id.evidence.contains { $0.field == "service" && $0.source == .plateText })
        XCTAssertTrue(id.evidence.contains { $0.field == "place" && $0.source == .gazetteer })
        XCTAssertTrue(id.consistency.contains { $0.contains("matches agency state") })
    }

    func testPartialReadingIsReportedAsAmbiguousNotGuessed() throws {
        let id = resolver.resolve(sceneText: [text("THAM")], plates: [massPolicePlate()],
                                  vehicleClass: .patrol, markings: FleetMarkings())
        let agency = try XCTUnwrap(id.agency)
        XCTAssertTrue(agency.needsReview)
        XCTAssertLessThanOrEqual(agency.confidence, 0.45)
        XCTAssertFalse(agency.alternatives.isEmpty)
    }

    func testLocationHintResolvesTheAmbiguity() throws {
        let nearWaltham = IdentityResolver.LocationHint(latitude: 42.39, longitude: -71.24)
        let id = resolver.resolve(sceneText: [text("THAM")], plates: [massPolicePlate()], vehicleClass: .patrol,
                                  markings: FleetMarkings(), location: nearWaltham)
        // "THAM" also fits Wrentham (~35 km), Chatham and Southampton; Waltham is right here.
        XCTAssertEqual(id.agency?.place, "Waltham")
        XCTAssertGreaterThanOrEqual(id.agency?.confidence ?? 0, 0.75)
        XCTAssertTrue(id.agency?.needsReview == true, "a fragment-based match still deserves a glance")
    }

    func testOCRErrorInPlaceNameStillResolves() {
        let id = resolver.resolve(sceneText: [text("WALTHAN")], plates: [massPolicePlate()],
                                  vehicleClass: .patrol, markings: FleetMarkings())
        XCTAssertEqual(id.agency?.place, "Waltham")
    }

    func testNoPlateStateMeansAmbiguousPlaceNeedsReview() throws {
        let m = SceneTextHeuristics.parse([text("AKRON FIRE DEPT.")])
        let id = resolver.resolve(sceneText: [text("AKRON FIRE DEPT.")], plates: [], vehicleClass: .fireEngine, markings: m)
        let agency = try XCTUnwrap(id.agency)
        XCTAssertEqual(agency.service, "Fire")
        XCTAssertTrue(agency.needsReview)
        XCTAssertFalse(agency.alternatives.isEmpty)
        // …but the phone's location settles it.
        let ohio = IdentityResolver.LocationHint(latitude: 41.08, longitude: -81.52)
        let located = resolver.resolve(sceneText: [text("AKRON FIRE DEPT.")], plates: [], vehicleClass: .fireEngine,
                                       markings: m, location: ohio)
        XCTAssertEqual(located.agency?.state, "OH")
        XCTAssertEqual(located.agency?.name, "Akron Fire Department")
    }

    func testStatePoliceAndHighwayPatrolAreStateLevel() {
        let m = SceneTextHeuristics.parse([text("WYOMING HIGHWAY PATROL")])
        let id = resolver.resolve(sceneText: [text("WYOMING HIGHWAY PATROL")], plates: [], vehicleClass: .highway, markings: m)
        XCTAssertEqual(id.agency?.name, "Wyoming Highway Patrol")
        XCTAssertEqual(id.agency?.agencyKey, "US-WY/state/highway-patrol")
    }

    func testSheriffResolvesToACounty() {
        let m = SceneTextHeuristics.parse([text("UTAH COUNTY"), text("SHERIFF")])
        let utPlate = PlateObservation(boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1),
                                       candidates: [Plate(text: "A12345", issuingRegion: "US-UT", confidence: 0.8)])
        let id = resolver.resolve(sceneText: [text("UTAH COUNTY"), text("SHERIFF")], plates: [utPlate],
                                  vehicleClass: .patrol, markings: m)
        XCTAssertEqual(id.agency?.name, "Utah County Sheriff's Office")
        XCTAssertEqual(id.agency?.placeKind, "county")
    }

    func testCivilianVehicleHasNoAgency() {
        let id = resolver.resolve(sceneText: [text("BABY ON BOARD")], plates: [], vehicleClass: .unknown, markings: FleetMarkings())
        XCTAssertNil(id.agency)
    }

    func testOutOfStatePlateIsFlaggedNotHidden() {
        let nyPlate = PlateObservation(boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1),
                                       candidates: [Plate(text: "ABC1234", issuingRegion: "US-NY", confidence: 0.8)])
        let m = SceneTextHeuristics.parse([text("WALTHAM POLICE")])
        let id = resolver.resolve(sceneText: [text("WALTHAM POLICE"), text("MASSACHUSETTS")], plates: [nyPlate],
                                  vehicleClass: .patrol, markings: m)
        XCTAssertTrue(id.consistency.contains { $0.contains("out-of-state") }, "\(id.consistency)")
    }

    func testBadgesBecomeAVehicleDescriptor() {
        let id = resolver.resolve(sceneText: [text("Ford"), text("POLICE INTERCEPTOR"), text("HYERID AWD")], plates: [],
                                  vehicleClass: .patrol, markings: FleetMarkings())
        XCTAssertEqual(id.vehicle.make, "Ford")
        XCTAssertEqual(id.vehicle.model, "Police Interceptor")
        XCTAssertTrue(id.vehicle.traits.contains("Hybrid"))
        XCTAssertTrue(id.vehicle.traits.contains("AWD"))
    }

    func testSameNameInSeveralStatesDoesNotPickOne() throws {
        let m = SceneTextHeuristics.parse([text("ATLANTA POLICE")])
        let id = resolver.resolve(sceneText: [text("ATLANTA POLICE")], plates: [], vehicleClass: .patrol, markings: m)
        let agency = try XCTUnwrap(id.agency)
        XCTAssertEqual(agency.place, "Atlanta")
        XCTAssertNil(agency.state, "nothing says which Atlanta — do not guess")
        XCTAssertTrue(agency.name.contains("state unknown"))
        XCTAssertEqual(agency.alternatives.first, "Atlanta, GA", "most prominent candidate first")
        XCTAssertTrue(agency.needsReview)
        XCTAssertNil(agency.latitude, "no centroid for an unresolved place")
    }

    func testAPlateSettlesWhichAtlanta() {
        let gaPlate = PlateObservation(boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1),
                                       candidates: [Plate(text: "GV4728R", issuingRegion: "US-GA", confidence: 0.8)])
        let m = SceneTextHeuristics.parse([text("ATLANTA POLICE")])
        let id = resolver.resolve(sceneText: [text("ATLANTA POLICE")], plates: [gaPlate], vehicleClass: .patrol, markings: m)
        XCTAssertEqual(id.agency?.name, "Atlanta Police Department")
        XCTAssertEqual(id.agency?.state, "GA")
        XCTAssertFalse(id.agency?.needsReview ?? true)
    }

    func testStatePoliceIsStateLevelAndKeepsItsVerbatimName() {
        let m = SceneTextHeuristics.parse([text("MICHIGAN STATE POLICE")])
        let id = resolver.resolve(sceneText: [text("MICHIGAN STATE POLICE")], plates: [], vehicleClass: .patrol, markings: m)
        XCTAssertEqual(id.agency?.name, "Michigan State Police")
        XCTAssertEqual(id.agency?.state, "MI")
        XCTAssertNil(id.agency?.place)
    }

    func testUnitNumbersMustContainADigit() {
        let m = SceneTextHeuristics.parse([text("UNIT OLL"), text("POLICE")])
        let id = resolver.resolve(sceneText: [text("UNIT OLL"), text("POLICE")], plates: [], vehicleClass: .patrol, markings: m)
        XCTAssertFalse(id.unitNumbers.contains("OLL"))
    }
}


final class IdentityRedactionTests: XCTestCase {
    func testRedactionRemovesTheRegistrationEverywhereButKeepsTheAgency() throws {
        let resolver = IdentityResolver()
        let plate = PlateObservation(boundingBox: .init(x: 0, y: 0, width: 0.1, height: 0.1),
                                     candidates: [Plate(text: "D756", issuingRegion: "US-MA", plateDesign: "government-official",
                                                        confidence: 0.9, officialWords: ["POLICE"])])
        let text = SceneTextObservation(text: "WALTHAM", boundingBox: .init(x: 0, y: 0, width: 0.2, height: 0.05), confidence: 0.9)
        let id = resolver.resolve(sceneText: [text], plates: [plate], vehicleClass: .patrol, markings: FleetMarkings())
        let safe = id.redactingRegistration()
        XCTAssertEqual(safe.plate?.registration, "")
        XCTAssertEqual(safe.plate?.state, "MA")
        XCTAssertFalse(safe.evidence.contains { $0.field == "registration" })
        XCTAssertFalse(String(data: try JSONEncoder().encode(safe), encoding: .utf8)!.contains("D756"),
                       "the registration must not appear anywhere in the encoded identity")
        XCTAssertEqual(safe.agency?.name, "Waltham Police Department")
    }
}

final class UserChoiceTests: XCTestCase {
    func testReviewerCanSettleAnAmbiguousState() {
        let text = SceneTextObservation(text: "ATLANTA POLICE", boundingBox: .init(x: 0, y: 0, width: 0.3, height: 0.05), confidence: 0.9)
        let m = SceneTextHeuristics.parse([text])
        let id = IdentityResolver().resolve(sceneText: [text], plates: [], vehicleClass: .patrol, markings: m, userState: "GA")
        XCTAssertEqual(id.agency?.name, "Atlanta Police Department")
        XCTAssertEqual(id.agency?.state, "GA")
        XCTAssertFalse(id.agency?.needsReview ?? true)
        XCTAssertTrue(id.evidence.contains { $0.source == .user })
    }
}

final class RealWorldRegressionTests: XCTestCase {
    private func text(_ s: String) -> SceneTextObservation {
        SceneTextObservation(text: s, boundingBox: .init(x: 0.1, y: 0.4, width: 0.2, height: 0.05), confidence: 0.9)
    }
    /// Seen in the app on the Waltham photo: Vision returned the plate line with no gap.
    func testGluedPlateLineIsStillAnOfficialPlate() {
        let r = Plate.officialRegistration(from: "Massachusetts POLICED756")
        XCTAssertEqual(r?.registration, "D756")
        XCTAssertEqual(r?.jurisdiction, "MASSACHUSETTS")
        XCTAssertEqual(Plate.officialWords(in: "POLICED756"), ["POLICE"])
        XCTAssertNil(Plate.officialRegistration(from: "POLICEMAN"), "ordinary words are never split")
        XCTAssertNil(Plate.officialRegistration(from: "POLICEMEN"))
    }
    /// Minneapolis photo: a Minnesota squad plate reads only "POLICE" — no digits.
    func testWordOnlyPlateNeedsOptInAndNeverCountsAsOfficial() {
        XCTAssertNil(Plate.officialRegistration(from: "POLICE"), "door lettering must never become a plate")
        let r = Plate.officialRegistration(from: "POLICE", allowWordOnly: true)
        XCTAssertEqual(r?.registration, "POLICE")
        let plate = Plate(text: "POLICE", plateDesign: r?.design, confidence: 0.9, officialWords: ["POLICE"])
        XCTAssertFalse(plate.isOfficialPlate, "a word-only plate must not earn the official-plate score bonus")
        XCTAssertNil(Plate.officialRegistration(from: "Minnesota", allowWordOnly: true))
    }
    /// Minneapolis photo: the hood reflects the car, so a smaller mirrored "555" appears beside the real "222".
    func testReflectedUnitNumberIsDropped() {
        func line(_ t: String, h: Double) -> SceneTextObservation {
            SceneTextObservation(text: t, boundingBox: .init(x: 0.3, y: 0.5, width: 0.05, height: h), confidence: 0.9)
        }
        let id = IdentityResolver().resolve(
            sceneText: [line("MINNEAPOLIS", h: 0.02), line("POLICE", h: 0.02), line("222", h: 0.022), line("555", h: 0.012)],
            plates: [], vehicleClass: .patrol, markings: FleetMarkings(), location: nil, enhancedText: [], userState: nil)
        XCTAssertEqual(id.unitNumbers, ["222"])
    }
    func testPlateTextIsNeverAUnitNumber() {
        let m = FleetMarkings(unitNumber: "POLICED756", serviceClassText: "POLICE", hasFleetKeyword: true)
        let id = IdentityResolver().resolve(sceneText: [text("POLICED756")], plates: [], vehicleClass: .patrol, markings: m)
        XCTAssertFalse(id.unitNumbers.contains("POLICED756"))
    }
    func testAFragmentSupportedTwiceBeatsOneSupportedOnce() throws {
        // "ALTHAM" only fits Waltham; "THAM" also fits Wrentham/Chatham/Southampton.
        let t = [text("ALTHAM"), text("THAM"), text("Massachusetts")]
        let id = IdentityResolver().resolve(sceneText: t, plates: [], vehicleClass: .patrol,
                                            markings: FleetMarkings(serviceClassText: "POLICE", hasFleetKeyword: true))
        let a = try XCTUnwrap(id.agency)
        XCTAssertEqual(a.place, "Waltham", "agency: \(a.name) alt \(a.alternatives)")
        XCTAssertEqual(a.state, "MA")
    }

    // MARK: - Sync identity for feed-sourced sightings

    private func minneapolisVehicle() -> (VehicleObservation, FleetMarkings) {
        func line(_ t: String) -> SceneTextObservation {
            SceneTextObservation(text: t, boundingBox: .init(x: 0.3, y: 0.5, width: 0.1, height: 0.02), confidence: 0.9)
        }
        let plate = PlateObservation(boundingBox: .init(x: 0.4, y: 0.55, width: 0.06, height: 0.03),
                                     candidates: [Plate(text: "D756", plateDesign: "government-official",
                                                        confidence: 0.9, officialWords: ["POLICE"])])
        let text = [line("MINNEAPOLIS"), line("POLICE"), line("222")]
        let v = VehicleObservation(boundingBox: .init(x: 0.2, y: 0.3, width: 0.5, height: 0.5),
                                   vehicleClass: .patrol, classConfidence: 0, plates: [plate], sceneText: text)
        return (v, SceneTextHeuristics.parse(text))
    }

    /// A feed camera's catalogued position settles "Minneapolis" (MN vs NC vs KS) exactly like phone GPS does.
    func testFeedCameraLocationSettlesTheState() throws {
        let (v, m) = minneapolisVehicle()
        let resolver = IdentityResolver()
        let none = resolver.syncIdentity(vehicle: v, markings: m, confidence: 0.95, location: nil)
        XCTAssertNil(none?.agency?.state, "no location → state unknown")
        let hint = try XCTUnwrap(IdentityResolver.LocationHint(geohash6: Geohash.encode(latitude: 44.9988, longitude: -93.2465)))
        let located = resolver.syncIdentity(vehicle: v, markings: m, confidence: 0.95, location: hint)
        XCTAssertEqual(located?.agency?.state, "MN")
        XCTAssertEqual(located?.agency?.agencyKey, "US-MN/minneapolis/police")
    }

    /// A low-resolution frame is never asserted as fact: review flag set, registration withheld.
    func testForcedReviewMarksAgencyAndStripsRegistration() throws {
        let (v, m) = minneapolisVehicle()
        let hint = IdentityResolver.LocationHint(geohash6: Geohash.encode(latitude: 44.9988, longitude: -93.2465))
        let resolver = IdentityResolver()
        let confident = try XCTUnwrap(resolver.syncIdentity(vehicle: v, markings: m, confidence: 0.95, location: hint))
        XCTAssertNotNil(confident.plate?.registration, "a fleet-confirmed full-resolution read may carry the plate")
        let forced = try XCTUnwrap(resolver.syncIdentity(vehicle: v, markings: m, confidence: 0.95, location: hint, forceReview: true))
        XCTAssertEqual(forced.agency?.needsReview, true)
        XCTAssertTrue(forced.plate?.registration.isEmpty ?? true, "registration stripped")
        let weak = try XCTUnwrap(resolver.syncIdentity(vehicle: v, markings: m, confidence: 0.6, location: hint))
        XCTAssertTrue(weak.plate?.registration.isEmpty ?? true, "below the plate bar the registration never leaves")
    }

    func testBadGeohashGivesNoHint() {
        XCTAssertNil(IdentityResolver.LocationHint(geohash6: "!!!"))
    }

    // MARK: - Jurisdiction policy (plate recognition)

    private func hint(_ lat: Double, _ lon: Double) -> IdentityResolver.LocationHint { .init(latitude: lat, longitude: lon) }

    func testPlateRecognitionIsDisabledInRestrictedStatesAndNearTheirBorders() {
        XCTAssertFalse(JurisdictionPolicy.mayReadPlates(near: hint(43.66, -70.26)), "Portland, ME")
        XCTAssertFalse(JurisdictionPolicy.mayReadPlates(near: hint(43.21, -71.54)), "Concord, NH")
        XCTAssertFalse(JurisdictionPolicy.mayReadPlates(near: hint(42.70, -71.16)), "Lawrence MA is ~10 km from NH: fail closed")
        XCTAssertFalse(JurisdictionPolicy.mayReadPlates(near: hint(34.75, -92.29)), "Little Rock, AR (pending counsel)")
    }

    func testPlateRecognitionIsAllowedAwayFromRestrictedStates() {
        XCTAssertTrue(JurisdictionPolicy.mayReadPlates(near: hint(44.98, -93.27)), "Minneapolis")
        XCTAssertTrue(JurisdictionPolicy.mayReadPlates(near: hint(42.36, -71.06)), "Boston is ~60 km from NH")
        XCTAssertTrue(JurisdictionPolicy.mayReadPlates(near: hint(34.05, -118.24)), "Los Angeles")
    }

    /// No location, or nowhere near any catalogued place, means no plate recognition.
    func testUnknownLocationFailsClosed() {
        XCTAssertFalse(JurisdictionPolicy.mayReadPlates(near: nil))
        XCTAssertFalse(JurisdictionPolicy.mayReadPlates(near: hint(0, -30)), "mid-Atlantic: nothing to reason from")
    }

    func testPolicyListsAreExplicit() {
        XCTAssertEqual(JurisdictionPolicy.platesRestricted, ["ME", "NH"])
        XCTAssertTrue(JurisdictionPolicy.platesDisabledByDefault.isSuperset(of: ["ME", "NH", "AR", "ID", "KY", "CT"]))
        XCTAssertTrue(JurisdictionPolicy.mayReadPlates(near: hint(43.66, -70.26), disabledStates: []), "counsel can clear a state")
    }
}
