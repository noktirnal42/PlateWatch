import XCTest
@testable import PlateKit

final class PlusCodeTests: XCTestCase {
    func testFullCodeDecodesToItsCentre() throws {
        let google = try XCTUnwrap(PlusCode.decode("849VCWC8+R9"))
        XCTAssertEqual(google.latitude, 37.4223, accuracy: 0.001)
        XCTAssertEqual(google.longitude, -122.0848, accuracy: 0.001)
        let zurich = try XCTUnwrap(PlusCode.decode("8FVC9G8F+6W"))
        XCTAssertEqual(zurich.latitude, 47.3656, accuracy: 0.001)
        XCTAssertEqual(zurich.longitude, 8.5248, accuracy: 0.001)
    }

    func testGridRefinedCodeIsMoreAccurate() throws {
        let area = try XCTUnwrap(PlusCode.decode("8FVC9G8F+6WQ"))
        XCTAssertLessThan(area.latitudeSize, 0.000125)
        XCTAssertEqual(area.latitude, 47.3656, accuracy: 0.001)
    }

    func testShortCodeIsRecoveredNearAReference() throws {
        XCTAssertTrue(PlusCode.isShort("9G8F+6W"))
        let area = try XCTUnwrap(PlusCode.decodeShort("9G8F+6W", nearLatitude: 47.4, longitude: 8.6))
        XCTAssertEqual(area.latitude, 47.3656, accuracy: 0.001)
        XCTAssertEqual(area.longitude, 8.5248, accuracy: 0.001)
    }

    func testMalformedCodesAreRejected() {
        XCTAssertNil(PlusCode.decode("not a code"))
        XCTAssertNil(PlusCode.decode("849VCWC8R9"))          // no separator
        XCTAssertNil(PlusCode.decode("9G8F+6W"))             // short, not full
        XCTAssertNil(PlusCode.decode("849VCWC8+R9+22"))
        XCTAssertNil(PlusCode.decode("ZZZZZZZZ+ZZ"))         // characters outside the alphabet
    }
}
