import XCTest

final class LiveFeedHealthTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 10_000)

    func testFreshDeliveryWithBusyAnalyzerDoesNotClaimCameraFreeze() {
        let health = LiveFeedHealth(now: now, received: now.addingTimeInterval(-1), analysed: now.addingTimeInterval(-30))
        XCTAssertEqual(health.delivery, .current)
        XCTAssertEqual(health.analysisAge, 30)
        XCTAssertEqual(health.deliveryText, "Frames arriving")
    }

    func testDelayedDeliveryEvenWhenAnalysisJustFinished() {
        let health = LiveFeedHealth(now: now, received: now.addingTimeInterval(-7), analysed: now)
        XCTAssertEqual(health.delivery, .delayed)
        XCTAssertEqual(health.analysisAge, 0)
    }

    func testSnapshotCadenceAndUnchangedContentAreSeparateFromDelivery() {
        let health = LiveFeedHealth(now: now, received: now.addingTimeInterval(-90), analysed: nil,
                                    changed: now.addingTimeInterval(-601), snapshotInterval: 60)
        XCTAssertEqual(health.delivery, .current)
        XCTAssertTrue(health.unchanged)
        XCTAssertEqual(health.analysisText, "Awaiting analysis")
        let overdue = LiveFeedHealth(now: now, received: now.addingTimeInterval(-121), analysed: nil, snapshotInterval: 60)
        XCTAssertEqual(overdue.delivery, .delayed)
    }

    func testWaitingAndClockSkew() {
        XCTAssertEqual(LiveFeedHealth(now: now, received: nil, analysed: nil).delivery, .waiting)
        let health = LiveFeedHealth(now: now, received: now.addingTimeInterval(5), analysed: now.addingTimeInterval(5))
        XCTAssertEqual(health.delivery, .current)
        XCTAssertEqual(health.analysisAge, 0)
    }
}
