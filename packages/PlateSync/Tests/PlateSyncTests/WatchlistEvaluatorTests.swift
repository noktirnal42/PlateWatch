import XCTest
@testable import PlateSync
import PlateKit

final class WatchlistEvaluatorTests: XCTestCase {
    private func frame(text: String, anchor: String? = nil) -> DetectionFrame {
        let plate = PlateObservation(
            boundingBox: NormalizedBox(x: 0, y: 0, width: 0.1, height: 0.05),
            candidates: [Plate(text: text, confidence: 0.9)])
        let vehicle = VehicleObservation(
            boundingBox: NormalizedBox(x: 0, y: 0, width: 0.2, height: 0.2),
            plates: [plate], featurePrintAnchorLookahead: anchor)
        return DetectionFrame(timestamp: Date(), imageSize: .init(width: 10, height: 10),
                              vehicles: [vehicle])
    }

    func testPlateHit() {
        let item = WatchlistItem(plateText: "1ABC234")
        let hits = WatchlistEvaluator.evaluate(frame(text: "1abc-234"), items: [item])
        XCTAssertEqual(hits.count, 1)
        XCTAssertEqual(hits.first?.matchedPlate, "1ABC234")
    }

    func testNoNotifyNoHit() {
        let item = WatchlistItem(plateText: "1ABC234", notifyEnabled: false)
        XCTAssertTrue(WatchlistEvaluator.evaluate(frame(text: "1ABC234"), items: [item]).isEmpty)
    }

    func testAnchorHit() {
        let item = WatchlistItem(featurePrintAnchor: "ff00aa")
        let hits = WatchlistEvaluator.evaluate(frame(text: "", anchor: "ff00aa"), items: [item])
        XCTAssertEqual(hits.count, 1)
    }

    func testMiss() {
        let item = WatchlistItem(plateText: "ZZZ999")
        XCTAssertTrue(WatchlistEvaluator.evaluate(frame(text: "1ABC234"), items: [item]).isEmpty)
    }
}
