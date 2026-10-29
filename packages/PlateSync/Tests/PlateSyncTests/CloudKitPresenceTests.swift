import CloudKit
import XCTest
@testable import PlateSync

final class CloudKitPresenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_792_000_000)

    func testRecordNameIsStableAndDoesNotContainTheSessionID() {
        let id = "session-0000000000000001"
        XCTAssertEqual(PresenceLease.recordName(forSessionID: id), PresenceLease.recordName(forSessionID: id))
        XCTAssertFalse(PresenceLease.recordName(forSessionID: id).contains(id))
        XCTAssertNotEqual(PresenceLease.recordName(forSessionID: id), PresenceLease.recordName(forSessionID: id + "x"))
    }

    func testLeaseRoundTripsThroughACloudKitRecordAndCapsFeedIDs() throws {
        let feeds = (0..<150).map { _ in UUID() }
        let beat = PresenceHeartbeat(sessionID: "session-0000000000000001", platform: "macOS-hub", feedIDs: feeds, activeProcessing: true,
                                     stats: PresenceStats(framesAnalyzed: 7, publicFeedFrames: 5, fleetHitsToday: 2, skippedWhileBusy: 1, outboxPending: 3))
        let lease = PresenceLease(heartbeat: beat, now: now)
        let record = CKRecord(recordType: PresenceLease.recordType, recordID: .init(recordName: "x"))
        lease.fill(record)
        let back = try XCTUnwrap(PresenceLease(record: record))
        XCTAssertEqual(back.feedIDs.count, 100)
        XCTAssertEqual(back.stats?.framesAnalyzed, 7)
        XCTAssertEqual(back.expiresAt, now.addingTimeInterval(PresenceLease.ttl))
        XCTAssertTrue(back.activeProcessing)
    }

    func testOnlyHubLeasesCarryStats() {
        let stats = PresenceStats(framesAnalyzed: 9, publicFeedFrames: 0, fleetHitsToday: 0, skippedWhileBusy: 0, outboxPending: 0)
        let phone = PresenceLease(heartbeat: .init(sessionID: "session-0000000000000002", platform: "iOS", feedIDs: [], activeProcessing: true, stats: stats), now: now)
        XCTAssertNil(phone.stats, "a phone cannot publish processing totals")
    }

    func testAggregateCountsOnlyUnexpiredLeasesAndSumsHubStats() {
        let feed = UUID()
        let hubStats = PresenceStats(framesAnalyzed: 100, publicFeedFrames: 60, fleetHitsToday: 4, skippedWhileBusy: 2, outboxPending: 1)
        let leases = [
            PresenceLease(platform: "macOS-hub", feedIDs: [feed], activeProcessing: true, expiresAt: now.addingTimeInterval(60), stats: hubStats),
            PresenceLease(platform: "iOS", feedIDs: [feed], activeProcessing: true, expiresAt: now.addingTimeInterval(10)),
            PresenceLease(platform: "iOS", feedIDs: [], activeProcessing: false, expiresAt: now.addingTimeInterval(10)),
            PresenceLease(platform: "iOS", feedIDs: [feed], activeProcessing: true, expiresAt: now.addingTimeInterval(-1)),
        ]
        let aggregate = PresenceAggregator.aggregate(leases, now: now)
        XCTAssertEqual(aggregate.activeSessions, 3)
        XCTAssertEqual(aggregate.activeProcessors, 2)
        XCTAssertEqual(aggregate.processorsByFeed[feed], 2)
        XCTAssertEqual(aggregate.stats?.framesAnalyzed, 100)
    }

    func testCloudKitErrorsMapToActionableStatus() {
        XCTAssertEqual(CloudKitPresenceClient.map(CKError(.unknownItem)), .schemaNotDeployed)
        XCTAssertEqual(CloudKitPresenceClient.map(CKError(.notAuthenticated)), .notSignedIn)
        XCTAssertEqual(PresenceError.schemaNotDeployed.statusText, "Offline · CloudKit schema not deployed")
    }
}
