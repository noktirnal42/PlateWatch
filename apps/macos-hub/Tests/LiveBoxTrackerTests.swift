import PlateKit
import XCTest

final class LiveBoxTrackerTests: XCTestCase {
    private func det(_ x: Double, _ label: String, fleet: Bool = false, uncertain: Bool = false) -> LiveBoxTracker.Detection {
        .init(rect: NormalizedBox(x: x, y: 0.4, width: 0.1, height: 0.1), label: label, isFleet: fleet, uncertain: uncertain)
    }

    func testABoxKeepsItsIdentityAsItMoves() {
        var tracker = LiveBoxTracker()
        let first = tracker.update([det(0.30, "Blue Car · class 61%")])
        let second = tracker.update([det(0.34, "Blue Car · class 58%")])
        XCTAssertEqual(first[0].id, second[0].id)
        XCTAssertEqual(second[0].hits, 2)
    }

    func testVelocityFollowsTheBoxAndIsZeroOnFirstSight() {
        var tracker = LiveBoxTracker()
        let first = tracker.update(now: 10, [det(0.30, "Blue Car")])
        XCTAssertEqual(first[0].velocity.x, 0)
        let second = tracker.update(now: 10.25, [det(0.35, "Blue Car")])
        XCTAssertEqual(second[0].velocity.x, 0.1, accuracy: 0.001)   // 0.05 over 0.25 s, halved by smoothing from 0 → 0.1
    }

    func testBoxIsDashedUntilAFullFrameClassifiesIt() {
        var tracker = LiveBoxTracker()
        XCTAssertTrue(tracker.update(authoritative: false, [det(0.3, "Car")])[0].uncertain)
        XCTAssertTrue(tracker.update(authoritative: false, [det(0.31, "Car")])[0].uncertain)
        XCTAssertFalse(tracker.update(authoritative: true, [det(0.32, "Blue Car · class 61%")])[0].uncertain)
        XCTAssertFalse(tracker.update(authoritative: false, [det(0.33, "Car")])[0].uncertain, "stays solid once classified")
    }

    func testLabelFlickerIsSmoothedButTheLatestScoreIsShown() {
        var tracker = LiveBoxTracker()
        var shown = ""
        for (i, label) in ["Blue Car · class 61%", "Blue Truck · class 40%", "Blue Car · class 66%", "Blue Truck · class 41%", "Blue Car · class 70%"].enumerated() {
            shown = tracker.update([det(0.30 + 0.01 * Double(i), label)])[0].label
        }
        XCTAssertEqual(shown, "Blue Car · class 70%")
    }

    func testFleetStatusAlwaysComesFromTheCurrentFrame() {
        var tracker = LiveBoxTracker()
        _ = tracker.update([det(0.3, "White Car · Patrol · fleet 91%", fleet: true)])
        _ = tracker.update([det(0.3, "White Car · Patrol · fleet 91%", fleet: true)])
        let notFleet = tracker.update([det(0.3, "White Car · class 52%", fleet: false)])
        XCTAssertFalse(notFleet[0].isFleet, "a past fleet frame must not keep a box green")
        let fleet = tracker.update([det(0.3, "White Car · Patrol · fleet 90%", fleet: true)])
        XCTAssertTrue(fleet[0].isFleet)
    }

    func testNonOverlappingVehicleGetsANewTrackAndGoneTracksExpire() {
        var tracker = LiveBoxTracker()
        let a = tracker.update([det(0.1, "Red Car")])[0].id
        let b = tracker.update([det(0.7, "Red Car")])[0].id
        XCTAssertNotEqual(a, b)
        for _ in 0...LiveBoxTracker.maxMisses + 1 { _ = tracker.update([]) }
        let again = tracker.update([det(0.1, "Red Car")])[0].id
        XCTAssertNotEqual(a, again, "an expired track is not resurrected")
    }

    func testUncertainStaysDashedOnlyWhileTheTypeIsUnknown() {
        var tracker = LiveBoxTracker()
        let unknown = tracker.update([det(0.3, "Vehicle · class 30%", uncertain: true)])
        XCTAssertTrue(unknown[0].uncertain)
        for _ in 0..<4 { _ = tracker.update([det(0.3, "Blue Car · class 60%", uncertain: false)]) }
        let flicker = tracker.update([det(0.3, "Vehicle · class 30%", uncertain: true)])
        XCTAssertFalse(flicker[0].uncertain, "after several 'Blue Car' frames one unknown frame does not turn the box dashed")
    }

    func testFastFramesMoveBoxesButKeepTheLastFullFrameVerdict() {
        var tracker = LiveBoxTracker()
        _ = tracker.update(authoritative: true, [det(0.30, "White Car · Patrol · fleet 91%", fleet: true)])
        let fast = tracker.update(authoritative: false, [det(0.33, "Vehicle · class 30%", uncertain: true)])
        XCTAssertEqual(fast[0].label, "White Car · Patrol · fleet 91%")
        XCTAssertTrue(fast[0].isFleet)
        XCTAssertEqual(fast[0].rect.x, 0.33, accuracy: 1e-9, "the box follows the vehicle")
        let fresh = tracker.update(authoritative: false, [det(0.70, "Vehicle · class 30%", uncertain: true)])
        XCTAssertFalse(fresh[0].isFleet, "a newly seen box starts as an ordinary vehicle until a full frame scores it")
        XCTAssertTrue(fresh[0].uncertain)
    }
}
