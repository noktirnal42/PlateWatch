import XCTest
@testable import EvalHarness

final class PlateMetricsTests: XCTestCase {
    func testCERNormalizesRegistrationPunctuation() {
        XCTAssertEqual(PlateMetrics.characterErrorRate(expected: "ABC-123", actual: "ABC123"), 0)
    }

    func testCERCountsSubstitutionsInsertionsAndDeletions() {
        XCTAssertEqual(PlateMetrics.characterErrorRate(expected: "ABC123", actual: "ABC12X"), 1.0 / 6.0, accuracy: 0.0001)
        XCTAssertEqual(PlateMetrics.characterErrorRate(expected: "ABC123", actual: "ABC12"), 1.0 / 6.0, accuracy: 0.0001)
    }

    func testEmptyExpectedPlateIsZeroOnlyWhenNothingWasRead() {
        XCTAssertEqual(PlateMetrics.characterErrorRate(expected: "", actual: ""), 0)
        XCTAssertEqual(PlateMetrics.characterErrorRate(expected: "", actual: "A"), 1)
    }
}
