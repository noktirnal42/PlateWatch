import XCTest
@testable import FeedIngest
import PlateKit

final class FeedIngestTests: XCTestCase {
    private let citation = SourceCitation(
        sourceType: .openDataPortal,
        url: URL(string: "https://mass511.com/cameras")!,
        retrievedAt: Date(timeIntervalSince1970: 1_760_000_000))

    private func source(refresh: TimeInterval = 5,
                        geohash: String = "drt2zq",
                        url: URL = URL(string: "https://example.gov/cam/1.jpg")!) -> PublicFeedSource {
        try! PublicFeedSource(name: "I-90 @ Exit 14", url: url, kind: .snapshotJPEG,
                              refreshInterval: refresh, geohash6: geohash, citation: citation,
                              termsNote: "public feed, 5 s cadence")
    }

    func testSourceValidation() {
        XCTAssertThrowsError(try PublicFeedSource(name: "x", url: URL(string: "https://a.b/c")!,
                                                  kind: .snapshotJPEG, refreshInterval: 0.2,
                                                  geohash: "drt2zq", citation: citation)) {
            XCTAssertEqual($0 as? PublicFeedSource.CreationError, .refreshIntervalTooAggressive)
        }
        XCTAssertThrowsError(try PublicFeedSource(name: "x", url: URL(string: "https://a.b/c")!,
                                                  kind: .hls, refreshInterval: 5,
                                                  geohash: "drt", citation: citation)) {
            XCTAssertEqual($0 as? PublicFeedSource.CreationError, .invalidGeohash)
        }
        XCTAssertEqual(source().kind, .snapshotJPEG)
    }

    func testScheduleHonorsRefreshInterval() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var s = FeedSchedule(refreshInterval: 5, now: t0)
        XCTAssertTrue(s.isDue(t0))
        s.recordSuccess(now: t0)
        XCTAssertFalse(s.isDue(t0.addingTimeInterval(4)))
        XCTAssertTrue(s.isDue(t0.addingTimeInterval(5)))
    }

    func testScheduleBacksOffAndSuspends() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        var s = FeedSchedule(refreshInterval: 5, now: t0, maxBackoff: 300)
        s.recordFailure(now: t0)                       // 10 s
        XCTAssertFalse(s.isDue(t0.addingTimeInterval(5)))
        XCTAssertTrue(s.isDue(t0.addingTimeInterval(10)))
        for _ in 0..<6 { s.recordFailure(now: t0) }    // cap at 300 s
        s.recordFailure(now: t0)                       // 8th → suspended
        XCTAssertTrue(s.isSuspended)
    }
}
