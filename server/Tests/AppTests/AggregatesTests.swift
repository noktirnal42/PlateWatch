import XCTest
@testable import App
import XCTVapor
import Vapor

final class KAnonymityTests: XCTestCase {
    func testBucketsBelowKAreWithheld() {
        let result = KAnonymity.suppress(["9v6kpv": 5, "9v6kpw": 4, "dqcjqc": 12])
        XCTAssertEqual(result.published.map(\.key), ["9v6kpv", "dqcjqc"])
        XCTAssertEqual(result.published.map(\.count), [5, 12])
        XCTAssertEqual(result.withheldBuckets, 1)
    }

    func testThresholdIsInclusive() {
        XCTAssertEqual(KAnonymity.k, 5)
        let at = KAnonymity.suppress(["a": KAnonymity.k])
        XCTAssertEqual(at.published.count, 1)
        let under = KAnonymity.suppress(["a": KAnonymity.k - 1])
        XCTAssertTrue(under.published.isEmpty)
        XCTAssertEqual(under.withheldBuckets, 1)
    }

    func testOutputIsSortedByKey() {
        let result = KAnonymity.suppress(["c": 9, "a": 9, "b": 9])
        XCTAssertEqual(result.published.map(\.key), ["a", "b", "c"])
    }

    func testEmptyInputIsEmptyOutput() {
        let result = KAnonymity.suppress([String: Int]())
        XCTAssertTrue(result.published.isEmpty)
        XCTAssertEqual(result.withheldBuckets, 0)
    }
}

final class AggregatesValidationTests: XCTestCase {
    func testRejectsInvertedWindowBeforeTouchingDatabase() async throws {
        try await withApp { app in
            try app.register(collection: AggregatesController())
            let res = try await app.sendRequest(
                .GET, "v1/aggregates/heatmap?since=2026-10-10T00:00:00Z&until=2026-10-01T00:00:00Z")
            XCTAssertEqual(res.status, .badRequest)
        }
    }

    func testRejectsWindowLongerThanMaximum() async throws {
        try await withApp { app in
            try app.register(collection: AggregatesController())
            let res = try await app.sendRequest(
                .GET, "v1/aggregates/heatmap?since=2024-01-01T00:00:00Z&until=2026-10-01T00:00:00Z")
            XCTAssertEqual(res.status, .badRequest)
        }
    }

    func testRejectsMalformedAgencyID() async throws {
        try await withApp { app in
            try app.register(collection: AggregatesController())
            let res = try await app.sendRequest(.GET, "v1/aggregates/heatmap?agencyID=not-a-uuid")
            XCTAssertEqual(res.status, .badRequest)
        }
    }

    func testRejectsMalformedDate() async throws {
        try await withApp { app in
            try app.register(collection: AggregatesController())
            let res = try await app.sendRequest(.GET, "v1/aggregates/heatmap?since=yesterday")
            XCTAssertEqual(res.status, .badRequest)
        }
    }
}
