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
            kind: .snapshotJPEG, refreshInterval: 1, geohash6: "drt2zq", citation: citation)
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
}
