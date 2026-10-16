import PlateKit
import XCTest
@testable import VehicleML

final class CameraEvaluationTests: XCTestCase {
    let a = NormalizedBox(x: 0.1, y: 0.2, width: 0.1, height: 0.1)
    let b = NormalizedBox(x: 0.5, y: 0.2, width: 0.1, height: 0.1)
    func testDuplicateDetectionCannotClaimSameVehicleTwice() throws {
        let result = try CameraEvaluation.score(expected: [a,b], predictions: [.init(box:a,confidence:0.9),.init(box:a,confidence:0.8)], exhaustive:true)
        XCTAssertEqual(result.truePositives, 1)
        XCTAssertEqual(result.falsePositives, 1)
        XCTAssertEqual(result.falseNegatives, 1)
        XCTAssertEqual(result.precision, 0.5)
        XCTAssertEqual(result.recall, 0.5)
    }
    func testPartialGroundTruthDoesNotInventFalsePositiveRate() throws {
        let result = try CameraEvaluation.score(expected: [a], predictions: [.init(box:a,confidence:0.9),.init(box:b,confidence:0.8)], exhaustive:false)
        XCTAssertEqual(result.truePositives, 1)
        XCTAssertNil(result.falsePositives)
        XCTAssertNil(result.precision)
        XCTAssertEqual(result.unmatchedPredictions, 1)
        XCTAssertEqual(result.recall, 1)
    }
    func testEmptyTruthAndInvalidPredictionsDoNotBecomePerfectAccuracy() throws {
        let invalid = NormalizedBox(x: .nan, y: 0.2, width: 0.1, height: 0.1)
        let result = try CameraEvaluation.score(expected: [], predictions: [.init(box:invalid,confidence:0.9)], exhaustive:true)
        XCTAssertEqual(result.falsePositives, 1)
        XCTAssertEqual(result.precision, 0)
        XCTAssertNil(result.recall)
        XCTAssertThrowsError(try CameraEvaluation.score(expected:[invalid], predictions:[], exhaustive:true))
        XCTAssertThrowsError(try CameraEvaluation.score(expected:[a], predictions:[], exhaustive:true, minimumIoU:0))
    }
    func testLowOverlapRemainsMissedAndNeighborDoesNotMatch() throws {
        let shifted = NormalizedBox(x: 0.18, y: 0.2, width: 0.1, height: 0.1)
        let result = try CameraEvaluation.score(expected:[a], predictions:[.init(box:shifted,confidence:0.99)], exhaustive:true)
        XCTAssertEqual(result.truePositives,0)
        XCTAssertEqual(result.falseNegatives,1)
        XCTAssertEqual(result.falsePositives,1)
    }
}
