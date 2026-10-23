import FeedIngest
import PlateKit
import XCTest

/// The Hub's ingest paths (folder drop, HTTP, public feeds) all call `FeedIdentity.resolve`; these pin the rules from
/// docs/IDENTITY.md and docs/FEED-SOURCES.md: the camera's position — not this Mac's — settles ambiguous places, marginal
/// frames are flagged for review without a registration, and the smallest frames assert no identity.
final class FeedIdentityTests: XCTestCase {
    private func line(_ s: String) -> SceneTextObservation {
        SceneTextObservation(text: s, boundingBox: .init(x: 0.1, y: 0.4, width: 0.2, height: 0.05), confidence: 0.9)
    }
    private func minneapolisVehicle() -> (VehicleObservation, FleetMarkings) {
        let plate = PlateObservation(boundingBox: .init(x: 0.4, y: 0.6, width: 0.2, height: 0.1),
                                     candidates: [Plate(text: "D756", plateDesign: "government-official",
                                                        confidence: 0.9, officialWords: ["POLICE"])])
        let text = [line("MINNEAPOLIS"), line("POLICE"), line("222")]
        let v = VehicleObservation(boundingBox: .init(x: 0.2, y: 0.3, width: 0.5, height: 0.5),
                                   vehicleClass: .patrol, classConfidence: 0, plates: [plate], sceneText: text)
        return (v, SceneTextHeuristics.parse(text))
    }
    private let minneapolisCamera = Geohash.encode(latitude: 44.9988, longitude: -93.2465)
    private let elsewhere = Geohash.encode(latitude: 35.78, longitude: -78.64)   // Raleigh, NC

    func testCameraPositionSettlesTheStateNotTheHubsLocation() throws {
        let (v, m) = minneapolisVehicle()
        let resolver = IdentityResolver()
        let mn = try XCTUnwrap(FeedIdentity.resolve(resolver: resolver, vehicle: v, markings: m, confidence: 0.95,
                                                          tier: .full, geohash6: minneapolisCamera))
        XCTAssertEqual(mn.agency?.agencyKey, "US-MN/minneapolis/police")
        XCTAssertNotEqual(FeedIdentity.resolve(resolver: resolver, vehicle: v, markings: m, confidence: 0.95,
                                                     tier: .full, geohash6: elsewhere)?.agency?.agencyKey,
                          "US-MN/minneapolis/police", "a camera far from Minneapolis must not resolve to the MN department")
    }

    func testReducedTierForcesReviewAndStripsRegistration() throws {
        let (v, m) = minneapolisVehicle()
        let id = try XCTUnwrap(FeedIdentity.resolve(resolver: IdentityResolver(), vehicle: v, markings: m, confidence: 0.95,
                                                          tier: .reduced, geohash6: minneapolisCamera))
        XCTAssertEqual(id.agency?.needsReview, true)
        XCTAssertTrue(id.plate?.registration.isEmpty ?? true)
    }

    func testAppearanceOnlyTierAssertsNoIdentity() {
        let (v, m) = minneapolisVehicle()
        XCTAssertNil(FeedIdentity.resolve(resolver: IdentityResolver(), vehicle: v, markings: m, confidence: 0.95,
                                                tier: .appearanceOnly, geohash6: minneapolisCamera))
    }

    func testSubmissionCarriesIdentityOnTheWire() throws {
        let (v, m) = minneapolisVehicle()
        let id = FeedIdentity.resolve(resolver: IdentityResolver(), vehicle: v, markings: m, confidence: 0.95,
                                            tier: .full, geohash6: minneapolisCamera)
        var dto = SightingSubmissionDTO(capturedAt: Date(), geohash6: minneapolisCamera, deviceIDHash: "d", fleetConfidence: 0.95,
                                        vehicle: VehicleObservationDTO(v), markings: FleetMarkingsDTO(m), identity: id)
        XCTAssertEqual(dto.identity?.agency?.agencyKey, "US-MN/minneapolis/police")
        let data = try JSONEncoder.withISODates.encode(dto)
        dto = try JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: data)
        XCTAssertEqual(dto.identity?.agency?.agencyKey, "US-MN/minneapolis/police")
    }
}
