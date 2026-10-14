import XCTest
import PlateKit
@testable import FeedIngest

final class FeedPolicyTests: XCTestCase {

    private func source(terms: FeedTerms = .unknown, side: Int? = nil,
                        location: LocationConfidence = .approximate) -> PublicFeedSource {
        try! PublicFeedSource(name: "cam", url: URL(string: "https://example.gov/cam.jpg")!, kind: .snapshotJPEG,
                              refreshInterval: 5, geohash6: "9zvxqy",
                              citation: SourceCitation(sourceType: .openDataPortal, url: URL(string: "https://example.gov/catalogue")!),
                              terms: terms, nativeLongSide: side, locationConfidence: location)
    }

    /// Boundaries follow the measured recall cliff (docs/FEED-SOURCES.md §1).
    func testTiersFollowResolution() {
        XCTAssertEqual(AnalysisTier.tier(forLongSide: 4032), .full)
        XCTAssertEqual(AnalysisTier.tier(forLongSide: 1280), .full)
        XCTAssertEqual(AnalysisTier.tier(forLongSide: 960), .full)
        XCTAssertEqual(AnalysisTier.tier(forLongSide: 704), .reduced)
        XCTAssertEqual(AnalysisTier.tier(forLongSide: 480), .reduced)
        XCTAssertEqual(AnalysisTier.tier(forLongSide: 352), .appearanceOnly)
        XCTAssertEqual(AnalysisTier.tier(forLongSide: 0), .appearanceOnly, "unknown size is the cautious tier")
        XCTAssertTrue(AnalysisTier.full.thorough && AnalysisTier.reduced.thorough)
        XCTAssertFalse(AnalysisTier.appearanceOnly.thorough)
        XCTAssertTrue(AnalysisTier.full.identityMayBeConfirmed)
        XCTAssertFalse(AnalysisTier.reduced.identityMayBeConfirmed)
        XCTAssertLessThan(AnalysisTier.full, AnalysisTier.appearanceOnly)
    }

    func testFrameSizeBeatsCatalogueClaim() {
        let s = source(side: 1920)
        XCTAssertEqual(s.analysisTier(frameLongSide: 352), .appearanceOnly, "what arrived, not what the catalogue says")
        XCTAssertEqual(s.analysisTier(frameLongSide: nil), .full)
        XCTAssertEqual(source().analysisTier(frameLongSide: nil), .appearanceOnly)
    }

    /// Nothing is analysed until a person read and recorded the terms.
    func testSourceMayBeAnalysedOnlyAfterHumanConfirmedTerms() {
        XCTAssertFalse(source().mayBeAnalysed, "default is not allowed")
        let url = URL(string: "https://example.gov/terms")!
        XCTAssertFalse(source(terms: .init(licenseClass: .publicDomain, automatedUseAllowed: true)).mayBeAnalysed, "no terms page recorded")
        XCTAssertFalse(source(terms: .init(licenseClass: .publicDomain, termsURL: url, termsReadOn: Date())).mayBeAnalysed, "not confirmed")
        XCTAssertFalse(source(terms: .init(licenseClass: .askFirst, termsURL: url, termsReadOn: Date(), automatedUseAllowed: true)).mayBeAnalysed)
        XCTAssertFalse(source(terms: .init(licenseClass: .unknown, termsURL: url, termsReadOn: Date(), automatedUseAllowed: true)).mayBeAnalysed)
        XCTAssertTrue(source(terms: .init(licenseClass: .publicDomain, termsURL: url, termsReadOn: Date(),
                                          attribution: "City of Austin", automatedUseAllowed: true)).mayBeAnalysed)
    }

    func testUnknownLocationBlocksIdentity() {
        XCTAssertTrue(source(location: .surveyed).mayResolveIdentity)
        XCTAssertTrue(source(location: .approximate).mayResolveIdentity)
        XCTAssertFalse(source(location: .unknown).mayResolveIdentity)
    }

    /// Catalogues saved before these fields existed must still load, as "not allowed".
    func testOldCatalogueDecodesWithSafeDefaults() throws {
        let json = """
        {"id":"\(UUID().uuidString)","name":"old","url":"https://example.gov/c.jpg","kind":"snapshotJPEG",
         "refreshInterval":10,"geohash6":"9zvxqy","termsNote":"",
         "citation":{"sourceType":"openDataPortal","retrievedAt":0}}
        """
        let decoded = try JSONDecoder().decode(PublicFeedSource.self, from: Data(json.utf8))
        XCTAssertFalse(decoded.mayBeAnalysed)
        XCTAssertEqual(decoded.terms.licenseClass, .unknown)
        XCTAssertNil(decoded.nativeLongSide)
    }

    func testRoundTrip() throws {
        let original = source(terms: .init(licenseClass: .openLicence, termsURL: URL(string: "https://e.gov/t")!,
                                           termsReadOn: Date(timeIntervalSince1970: 1_800_000_000),
                                           attribution: "Agency", automatedUseAllowed: true), side: 704)
        let data = try JSONEncoder().encode(original)
        XCTAssertEqual(try JSONDecoder().decode(PublicFeedSource.self, from: data), original)
    }

    /// Thresholds come from the measured detection rate by vehicle size, not from frame size.
    func testVehicleTierFollowsVehiclePixelSize() {
        XCTAssertEqual(AnalysisTier.tier(forVehicleLongSide: 1500), .full)
        XCTAssertEqual(AnalysisTier.tier(forVehicleLongSide: 900), .full)
        XCTAssertEqual(AnalysisTier.tier(forVehicleLongSide: 899), .reduced)
        XCTAssertEqual(AnalysisTier.tier(forVehicleLongSide: 400), .reduced)
        XCTAssertEqual(AnalysisTier.tier(forVehicleLongSide: 399), .appearanceOnly)
        XCTAssertEqual(AnalysisTier.tier(forVehicleLongSide: 60), .appearanceOnly, "a distant car in a 1080p frame")
        XCTAssertEqual(AnalysisTier.tier(forVehicleLongSide: 0), .appearanceOnly)
    }

    /// A big frame does not make a tiny vehicle readable, and a small frame cannot make a vehicle better.
    func testCombinedTierIsTheWorseOfFrameAndVehicle() {
        XCTAssertEqual(AnalysisTier.combined(frame: .full, vehicle: .appearanceOnly), .appearanceOnly)
        XCTAssertEqual(AnalysisTier.combined(frame: .reduced, vehicle: .full), .reduced)
        XCTAssertEqual(AnalysisTier.combined(frame: .full, vehicle: .full), .full)
        XCTAssertEqual(AnalysisTier.combined(frame: .appearanceOnly, vehicle: .full), .appearanceOnly)
    }
}
