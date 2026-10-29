import XCTest
import PlateKit
@testable import FeedIngest

final class FeedPlaceIndexTests: XCTestCase {
    private let index = FeedPlaceIndex()

    func testKnownCameraPositionsGetTheRightCityAndState() throws {
        // Spokane WA, Reno NV, Salt Lake City UT, Austin TX — geography decides the state, not the feed's host.
        let cases: [(Double, Double, String, String)] = [
            (47.6588, -117.4260, "Spokane", "WA"), (39.5296, -119.8138, "Reno", "NV"),
            (40.7608, -111.8910, "Salt Lake City", "UT"), (30.2672, -97.7431, "Austin", "TX"),
        ]
        for (lat, lon, city, state) in cases {
            let p = try XCTUnwrap(index.place(latitude: lat, longitude: lon), city)
            XCTAssertEqual(p.city, city); XCTAssertEqual(p.state, state)
        }
    }

    func testOpenCountryOutsideRangeGetsNoLabel() {
        // Middle of the Pacific and a spot in the Great Basin far from any Census place.
        XCTAssertNil(index.place(latitude: 30, longitude: -140))
    }

    func testSourceUsesItsGeohash() throws {
        let hash = Geohash.encode(latitude: 47.6588, longitude: -117.4260, precision: 6)
        let source = try PublicFeedSource(name: "x", url: URL(string: "https://www.tripcheck.com/cam.jpg")!, kind: .snapshotJPEG,
                                          refreshInterval: 300, geohash6: hash,
                                          citation: .init(sourceType: .openDataPortal, url: nil, retrievedAt: Date()), termsNote: "", state: "OR")
        XCTAssertEqual(index.place(for: source)?.label, "Spokane, WA", "a tripcheck.com camera recorded as OR is labelled by where it is")
    }
}
