import Foundation
import XCTest
@testable import FeedIngest
import PlateKit

/// URLProtocol stub so poller tests never touch the network.
final class StubProtocol: URLProtocol {
    nonisolated(unsafe) static var responder: ((URLRequest) -> (Int, String, Data))? = nil
    nonisolated(unsafe) static var requestCount = 0

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
                                   headerFields: ["Content-Type": type])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Collects frames; records what the poller delivered.
final class CollectingSink: FeedFrameSink {
    let actor = FrameCollector()
    func accept(_ frameData: Data, from source: PublicFeedSource) async {
        await actor.add(frameData, source)
    }
}

actor FrameCollector {
    private(set) var frames: [(Data, PublicFeedSource)] = []
    func add(_ d: Data, _ s: PublicFeedSource) { frames.append((d, s)) }
}

final class SnapshotPollerTests: XCTestCase {
    private let citation = SourceCitation(sourceType: .openDataPortal, retrievedAt: Date(timeIntervalSince1970: 0))
    private let jpeg = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x11, count: 64)

    private func makeSource() -> PublicFeedSource {
        try! PublicFeedSource(
            name: "test cam", url: URL(string: "https://example.gov/cam.jpg")!,
            kind: .snapshotJPEG, refreshInterval: 1, geohash6: "drt2zq", citation: citation,
            terms: .init(licenseClass: .publicDomain, termsURL: URL(string: "https://example.gov/terms")!,
                         termsReadOn: Date(timeIntervalSince1970: 1_800_000_000), automatedUseAllowed: true))
    }

    /// A source nobody confirmed the terms of must cause **no network request at all**.
    func testUnconfirmedSourceIsNeverContacted() async {
        StubProtocol.responder = { _ in (200, "image/jpeg", self.jpeg) }
        let unconfirmed = try! PublicFeedSource(
            name: "unconfirmed", url: URL(string: "https://example.gov/cam.jpg")!, kind: .snapshotJPEG,
            refreshInterval: 1, geohash6: "drt2zq", citation: citation)
        let sink = CollectingSink()
        let poller = SnapshotPoller(source: unconfirmed, sink: sink, session: makeSession())
        XCTAssertFalse(poller.isPermitted)
        var schedule = FeedSchedule(refreshInterval: 1)
        _ = await poller.pollOnce(schedule: &schedule, now: Date(timeIntervalSince1970: 5_000))
        XCTAssertEqual(StubProtocol.requestCount, 0)
        let frames = await sink.actor.frames.count
        XCTAssertEqual(frames, 0)
        // Opting out (tests, the owner's own camera) is explicit.
        let own = SnapshotPoller(source: unconfirmed, sink: sink, session: makeSession(), enforceTerms: false)
        XCTAssertTrue(own.isPermitted)
    }

    private func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        return URLSession(configuration: config)
    }

    override func tearDown() {
        StubProtocol.responder = nil
        StubProtocol.requestCount = 0
    }

    func testOutcomeSeparatesCameraHTTPAndMediaFailuresFromSuccess() async {
        let log = PollOutcomeLog()
        let source = makeSource()
        let sink = CollectingSink()
        let poller = SnapshotPoller(source: source, sink: sink, session: makeSession(), onOutcome: { await log.add($0) })
        var schedule = FeedSchedule(refreshInterval: 1, now: .distantPast)
        StubProtocol.responder = { _ in (503, "text/html", Data("busy".utf8)) }
        _ = await poller.pollOnce(schedule: &schedule, now: Date(timeIntervalSince1970: 10))
        StubProtocol.responder = { _ in (200, "text/html", Data("<html>offline</html>".utf8)) }
        _ = await poller.pollOnce(schedule: &schedule, now: Date(timeIntervalSince1970: 20))
        StubProtocol.responder = { _ in (200, "image/jpeg", self.jpeg) }
        let received = Date(timeIntervalSince1970: 30)
        _ = await poller.pollOnce(schedule: &schedule, now: received)
        let outcomes = await log.outcomes
        XCTAssertEqual(outcomes, [.httpFailure(503), .unreadableImage, .received(received)])
        XCTAssertEqual(schedule.consecutiveFailures, 0)
    }

    func testFetchesDeliverJPEGsToSink() async {
        StubProtocol.responder = { _ in (200, "image/jpeg", self.jpeg) }
        let source = makeSource()
        let sink = CollectingSink()
        let poller = SnapshotPoller(source: source, sink: sink, session: makeSession())
        var schedule = FeedSchedule(refreshInterval: source.refreshInterval, now: .distantPast)
        schedule = await poller.pollOnce(schedule: &schedule, now: Date(timeIntervalSince1970: 10))
        let frames = await sink.actor.frames
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.1.id, source.id)
        XCTAssertFalse(schedule.isDue(Date(timeIntervalSince1970: 10)))
        XCTAssertTrue(schedule.isDue(Date(timeIntervalSince1970: 11)))
    }

    func testBackoffAfterServerError() async {
        StubProtocol.responder = { _ in (503, "text/html", Data("busy".utf8)) }
        let source = makeSource()
        let sink = CollectingSink()
        let poller = SnapshotPoller(source: source, sink: sink, session: makeSession())
        var schedule = FeedSchedule(refreshInterval: source.refreshInterval, now: .distantPast)
        schedule = await poller.pollOnce(schedule: &schedule, now: Date(timeIntervalSince1970: 10))
        let frames = await sink.actor.frames
        XCTAssertTrue(frames.isEmpty)
        // 1 s interval → backoff to 2 s, not 1 s.
        XCTAssertFalse(schedule.isDue(Date(timeIntervalSince1970: 11)))
        XCTAssertTrue(schedule.isDue(Date(timeIntervalSince1970: 12)))
    }

    func testRefusesNonImagePayloads() async {
        StubProtocol.responder = { _ in (200, "text/html", Data("<html>cam portal</html>".utf8)) }
        let source = makeSource()
        let sink = CollectingSink()
        let poller = SnapshotPoller(source: source, sink: sink, session: makeSession())
        var schedule = FeedSchedule(refreshInterval: source.refreshInterval, now: .distantPast)
        schedule = await poller.pollOnce(schedule: &schedule, now: Date(timeIntervalSince1970: 10))
        let frames = await sink.actor.frames
        XCTAssertTrue(frames.isEmpty, "HTML must not reach the pipeline")
        XCTAssertEqual(schedule.consecutiveFailures, 1)
    }

    func testSuspendsAfterRepeatedFailures() async {
        StubProtocol.responder = { _ in (404, "text/plain", Data()) }
        let source = makeSource()
        let sink = CollectingSink()
        let poller = SnapshotPoller(source: source, sink: sink, session: makeSession())
        var schedule = FeedSchedule(refreshInterval: source.refreshInterval, now: .distantPast, maxBackoff: 0.01)
        var now = Date(timeIntervalSince1970: 1_000)
        for _ in 0..<(FeedSchedule.suspensionThreshold + 1) {
            now = schedule.nextFetchAt
            schedule = await poller.pollOnce(schedule: &schedule, now: now)
        }
        XCTAssertTrue(schedule.isSuspended)
        let frames = await sink.actor.frames
        XCTAssertTrue(frames.isEmpty)
    }

    /// A gate that says no stops the poller before any request is made (robots.txt disallow).
    func testGateThatRefusesStopsThePollerWithoutAnyRequest() async {
        StubProtocol.responder = { _ in (200, "image/jpeg", self.jpeg) }
        let source = makeSource()
        let sink = CollectingSink()
        let poller = SnapshotPoller(source: source, sink: sink, session: makeSession(), gate: { _ in false })
        await poller.run(sink: sink)                       // returns immediately instead of looping forever
        XCTAssertEqual(StubProtocol.requestCount, 0)
    }

    func testGateThatAllowsLetsTheFetchThrough() async {
        StubProtocol.responder = { _ in (200, "image/jpeg", self.jpeg) }
        let source = makeSource()
        let sink = CollectingSink()
        let seen = GateRecorder()
        let poller = SnapshotPoller(source: source, sink: sink, session: makeSession(),
                                    gate: { url in await seen.record(url); return true })
        let task = Task { await poller.run(sink: sink) }
        try? await Task.sleep(for: .milliseconds(300))
        task.cancel()
        let urls = await seen.urls
        XCTAssertFalse(urls.isEmpty)
        XCTAssertEqual(urls.first, source.url, "the gate is asked about the exact URL that would be fetched")
        XCTAssertGreaterThanOrEqual(StubProtocol.requestCount, 1)
    }
}

actor GateRecorder {
    private(set) var urls: [URL] = []
    func record(_ url: URL) { urls.append(url) }
}

private actor PollOutcomeLog {
    var outcomes: [SnapshotPoller.Outcome] = []
    func add(_ outcome: SnapshotPoller.Outcome) { outcomes.append(outcome) }
}
