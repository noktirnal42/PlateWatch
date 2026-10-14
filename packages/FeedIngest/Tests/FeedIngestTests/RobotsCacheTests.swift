import Foundation
import XCTest
@testable import FeedIngest

/// Separate stub protocol for cache tests to avoid conflicts with SnapshotPollerTests.
final class RobotsStubProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, String, Data))? = nil
    nonisolated(unsafe) static var requestCount = 0
    /// Extra response headers (e.g. `Server`), reset by tests that set them.
    nonisolated(unsafe) static var extraHeaders: [String: String] = [:]

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requestCount += 1
        guard let respond = Self.responder else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        let (status, type, body) = respond(request)
        let http = HTTPURLResponse(url: request.url!, statusCode: status,
                                   httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": type].merging(Self.extraHeaders) { $1 })!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Simple box for mutable clock value (nonisolated(unsafe) for test use).
final class ClockBox: @unchecked Sendable {
    var now: Date
    init(_ date: Date) { self.now = date }
}

final class RobotsCacheTests: XCTestCase {
    private let userAgent = "PlateWatchHub/1.0"

    private func makeCache(session: URLSession? = nil, ttl: TimeInterval = 86_400, clock: ClockBox) -> RobotsCache {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RobotsStubProtocol.self]
        let sess = session ?? URLSession(configuration: config)
        return RobotsCache(session: sess, userAgent: userAgent, ttl: ttl, now: { clock.now })
    }

    private func makeURL(path: String = "/page") -> URL {
        URL(string: "https://example.com\(path)")!
    }

    override func tearDown() {
        RobotsStubProtocol.responder = nil
        RobotsStubProtocol.requestCount = 0
    }

    // MARK: - Basic Allow/Disallow

    func test200ParseAndAllow() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        RobotsStubProtocol.responder = { _ in
            (200, "text/plain", Data("User-agent: *\nDisallow: /private/\n".utf8))
        }
        let cache = makeCache(clock: clock)
        let allowed = await cache.isAllowed(makeURL(path: "/public"))
        let disallowed = await cache.isAllowed(makeURL(path: "/private/page"))
        XCTAssertTrue(allowed)
        XCTAssertFalse(disallowed)
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)
    }

    func test404MeansAllowAll() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        RobotsStubProtocol.responder = { _ in (404, "text/plain", Data()) }
        let cache = makeCache(clock: clock)
        let allowed = await cache.isAllowed(makeURL(path: "/anything"))
        XCTAssertTrue(allowed)
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)
    }

    func test500MeansDisallowAll() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        RobotsStubProtocol.responder = { _ in (500, "text/plain", Data("server error".utf8)) }
        let cache = makeCache(clock: clock)
        let allowed = await cache.isAllowed(makeURL(path: "/anything"))
        XCTAssertFalse(allowed)
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)
    }

    func testNetworkErrorMeansDisallowAll() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        RobotsStubProtocol.responder = { _ in (0, "text/plain", Data()) }
        let cache = makeCache(clock: clock)
        let allowed = await cache.isAllowed(makeURL(path: "/anything"))
        XCTAssertFalse(allowed)
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)
    }

    // MARK: - Caching

    func testCachingWithinTTL() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        RobotsStubProtocol.responder = { _ in
            (200, "text/plain", Data("User-agent: *\nDisallow: /private/\n".utf8))
        }
        let cache = makeCache(ttl: 86_400, clock: clock)

        // First call - fetches
        _ = await cache.isAllowed(makeURL(path: "/public"))
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)

        // Second call within TTL - uses cache
        _ = await cache.isAllowed(makeURL(path: "/public"))
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)

        // Third call - still cached
        _ = await cache.isAllowed(makeURL(path: "/private/page"))
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)
    }

    func testRefetchAfterTTL() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        var callCount = 0
        RobotsStubProtocol.responder = { _ in
            callCount += 1
            if callCount == 1 {
                return (200, "text/plain", Data("User-agent: *\nDisallow: /v1/\n".utf8))
            } else {
                return (200, "text/plain", Data("User-agent: *\nDisallow: /v2/\n".utf8))
            }
        }
        let cache = makeCache(ttl: 100, clock: clock)

        // First fetch
        _ = await cache.isAllowed(makeURL(path: "/v1/page"))
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)

        // Advance time past TTL
        clock.now = clock.now.addingTimeInterval(101)

        // Second fetch should use new rules
        _ = await cache.isAllowed(makeURL(path: "/v2/page"))
        XCTAssertEqual(RobotsStubProtocol.requestCount, 2)
    }

    func testFailureCachedFor10Minutes() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        RobotsStubProtocol.responder = { _ in (500, "text/plain", Data()) }
        let cache = makeCache(clock: clock)

        // First call - 500, caches disallow
        let allowed1 = await cache.isAllowed(makeURL(path: "/page"))
        XCTAssertFalse(allowed1)
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)

        // Second call within 10 min - uses cached failure
        let allowed2 = await cache.isAllowed(makeURL(path: "/page"))
        XCTAssertFalse(allowed2)
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)

        // Advance past 10 min (600 seconds)
        clock.now = clock.now.addingTimeInterval(601)

        // Now allow responder to succeed
        RobotsStubProtocol.responder = { _ in
            (200, "text/plain", Data("User-agent: *\nDisallow:\n".utf8))
        }

        // Should refetch and now allow
        let allowed3 = await cache.isAllowed(makeURL(path: "/page"))
        XCTAssertTrue(allowed3)
        XCTAssertEqual(RobotsStubProtocol.requestCount, 2)
    }

    // MARK: - Single Flight

    func testConcurrentCallsShareFetch() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        var fetchCount = 0
        RobotsStubProtocol.responder = { _ in
            fetchCount += 1
            return (200, "text/plain", Data("User-agent: *\nDisallow:\n".utf8))
        }
        let cache = makeCache(clock: clock)

        let urlA = makeURL(path: "/a")
        let urlB = makeURL(path: "/b")
        let urlC = makeURL(path: "/c")

        // Call concurrently using TaskGroup to avoid async let isolation issues
        let results = await withTaskGroup(of: Bool.self) { group in
            group.addTask { await cache.isAllowed(urlA) }
            group.addTask { await cache.isAllowed(urlB) }
            group.addTask { await cache.isAllowed(urlC) }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            return results
        }

        XCTAssertEqual(results.count, 3)
        XCTAssertTrue(results.allSatisfy { $0 })
        XCTAssertEqual(fetchCount, 1) // Only one fetch should happen
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)
    }

    // MARK: - Body Size Limit

    func testLargeBodyDoesNotCrash() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        // 600 KiB body (over 500 KiB limit)
        let largeBody = String(repeating: "User-agent: *\nDisallow: /x\n", count: 20000)
        RobotsStubProtocol.responder = { _ in
            (200, "text/plain", Data(largeBody.utf8))
        }
        let cache = makeCache(clock: clock)

        // Should not crash, should parse what it can
        let allowed = await cache.isAllowed(makeURL(path: "/page"))
        // The truncated body may or may not have complete rules
        // Just verify no crash
        _ = allowed
        XCTAssertEqual(RobotsStubProtocol.requestCount, 1)
    }

    // MARK: - Different Hosts Have Separate Cache

    func testSeparateHostsSeparateCache() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        let exampleComRules = "User-agent: *\nDisallow: /private\n"
        let otherComRules = "User-agent: *\nDisallow:\n"

        RobotsStubProtocol.responder = { request in
            let host = request.url?.host ?? ""
            if host == "example.com" {
                return (200, "text/plain", Data(exampleComRules.utf8))
            } else {
                return (200, "text/plain", Data(otherComRules.utf8))
            }
        }

        let cache = makeCache(clock: clock)
        let allowed1 = await cache.isAllowed(URL(string: "https://example.com/private/page")!)
        let allowed2 = await cache.isAllowed(URL(string: "https://other.com/private/page")!)

        XCTAssertFalse(allowed1) // example.com disallows /private
        XCTAssertTrue(allowed2)  // other.com allows all
        XCTAssertEqual(RobotsStubProtocol.requestCount, 2)
    }

    // MARK: - Port Included in Cache Key

    func testDifferentPortsSeparateCache() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        RobotsStubProtocol.responder = { request in
            let port = request.url?.port ?? 443
            if port == 443 {
                return (200, "text/plain", Data("User-agent: *\nDisallow: /private\n".utf8))
            } else {
                return (200, "text/plain", Data("User-agent: *\nDisallow:\n".utf8))
            }
        }

        let cache = makeCache(clock: clock)
        let allowed1 = await cache.isAllowed(URL(string: "https://example.com:443/private/page")!)
        let allowed2 = await cache.isAllowed(URL(string: "https://example.com:8443/private/page")!)

        XCTAssertFalse(allowed1)
        XCTAssertTrue(allowed2)
        XCTAssertEqual(RobotsStubProtocol.requestCount, 2)
    }

    // MARK: - Path and Query

    func testQueryStringInPath() async {
        let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
        RobotsStubProtocol.responder = { _ in
            (200, "text/plain", Data("User-agent: *\nDisallow: /search?\n".utf8))
        }
        let cache = makeCache(clock: clock)
        let allowed1 = await cache.isAllowed(URL(string: "https://example.com/search?q=test")!)
        let allowed2 = await cache.isAllowed(URL(string: "https://example.com/search")!)
        XCTAssertFalse(allowed1)
        XCTAssertTrue(allowed2)
    }

    // MARK: - Stop and flag (stricter than RFC 9309's "any 4xx = allow")

    /// The host refusing or rate-limiting us is a reason to stop, not a green light; and it is cached so we do not hammer.
    func testRefusalAndRateLimitStatusesDisallowAndAreCached() async {
        for status in [401, 403, 429] {
            RobotsStubProtocol.requestCount = 0
            RobotsStubProtocol.responder = { _ in (status, "text/plain", Data()) }
            let clock = ClockBox(Date(timeIntervalSince1970: 1_000_000_000))
            let cache = makeCache(clock: clock)
            let first = await cache.isAllowed(makeURL())
            let second = await cache.isAllowed(makeURL(path: "/other"))
            XCTAssertFalse(first, "HTTP \(status) must disallow")
            XCTAssertFalse(second)
            XCTAssertEqual(RobotsStubProtocol.requestCount, 1, "HTTP \(status): failure is cached, no hammering")
            clock.now = clock.now.addingTimeInterval(601)
            _ = await cache.isAllowed(makeURL())
            XCTAssertEqual(RobotsStubProtocol.requestCount, 2, "retried after the 10-minute failure cache")
        }
    }

    func testOrdinary404StillMeansAllowAll() async {
        RobotsStubProtocol.responder = { _ in (404, "text/plain", Data("nope".utf8)) }
        let cache = makeCache(clock: ClockBox(Date(timeIntervalSince1970: 1_000_000_000)))
        let allowed = await cache.isAllowed(makeURL())
        XCTAssertTrue(allowed)
    }

    /// An S3/CloudFront host answers a missing robots.txt with 403 AccessDenied — that is "no robots.txt", not a refusal.
    func testS3AccessDeniedForMissingRobotsMeansAllowAll() async {
        RobotsStubProtocol.extraHeaders = ["Server": "AmazonS3"]
        defer { RobotsStubProtocol.extraHeaders = [:] }
        RobotsStubProtocol.responder = { _ in
            (403, "application/xml", Data("<?xml version=\"1.0\"?><Error><Code>AccessDenied</Code><Message>Access Denied</Message></Error>".utf8))
        }
        let cache = makeCache(clock: ClockBox(Date(timeIntervalSince1970: 1_000_000_000)))
        let allowed = await cache.isAllowed(makeURL())
        XCTAssertTrue(allowed)
    }

    /// The exception is narrow: a plain 403, or a 403 from a non-S3 server with the same body, still stops us.
    func testOtherForbiddenResponsesStillDisallow() async {
        let s3Body = Data("<Error><Code>AccessDenied</Code></Error>".utf8)
        for (headers, body) in [([String: String](), Data()), ([:], s3Body), (["Server": "AmazonS3"], Data("<Error><Code>SignatureDoesNotMatch</Code></Error>".utf8))] {
            RobotsStubProtocol.extraHeaders = headers
            RobotsStubProtocol.responder = { _ in (403, "application/xml", body) }
            let cache = makeCache(clock: ClockBox(Date(timeIntervalSince1970: 1_000_000_000)))
            let allowed = await cache.isAllowed(makeURL())
            XCTAssertFalse(allowed)
        }
        RobotsStubProtocol.extraHeaders = [:]
    }
}
