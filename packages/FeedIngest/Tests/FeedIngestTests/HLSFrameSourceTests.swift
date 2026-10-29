import CoreVideo
import Foundation
import PlateKit
import XCTest
@testable import FeedIngest

private final class HLSCountingSink: LiveFrameSink, @unchecked Sendable {
    private let lock = NSLock()
    private var total = 0
    private var active = 0
    private var peak = 0
    var counts: (total: Int, peak: Int) { lock.withLock { (total, peak) } }
    func accept(_ pixelBuffer: CVPixelBuffer, from source: PublicFeedSource) async {
        lock.withLock { total += 1; active += 1; peak = max(peak, active) }
        try? await Task.sleep(for: .milliseconds(150))
        lock.withLock { active -= 1 }
    }
}

final class HLSFrameSourceTests: XCTestCase {
    private func source(_ url: URL) throws -> PublicFeedSource {
        try .init(name: "Synthetic local HLS fixture", url: url, kind: .hls, refreshInterval: 1,
                  geohash6: "9q8yyk", citation: .init(sourceType: .openDataPortal, url: url))
    }

    @MainActor
    func testUnknownTermsNeverStartDecoder() throws {
        let decoder = HLSFrameSource(source: try source(URL(string: "https://example.gov/test.m3u8")!))
        decoder.start(sink: HLSCountingSink())
        XCTAssertFalse(decoder.isRunning)
        XCTAssertEqual(decoder.state, .stopped)
        decoder.stop()
    }

    private func localFixture() throws -> URL {
        guard let raw = ProcessInfo.processInfo.environment["PLATEWATCH_HLS_FIXTURE_URL"],
              let url = URL(string: raw), url.host == "127.0.0.1", url.pathExtension == "m3u8" else {
            throw XCTSkip("Opt-in: serve generated HLS on loopback and set PLATEWATCH_HLS_FIXTURE_URL")
        }
        return url
    }

    @MainActor
    func testLocalHLSDeliversBoundedFramesAndRestarts() async throws {
        let url = try localFixture()
        let sink = HLSCountingSink()
        let decoder = HLSFrameSource(source: try source(url), enforceTerms: false, stallTimeout: 8, retryDelay: 0.2)
        defer { decoder.stop() }
        decoder.start(sink: sink)
        let firstDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while sink.counts.total < 3, ContinuousClock.now < firstDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThanOrEqual(sink.counts.total, 3)
        XCTAssertEqual(decoder.state, .streaming)
        XCTAssertEqual(sink.counts.peak, 1, "Slow sinks must never accumulate delivery tasks")
        decoder.stop()
        try await Task.sleep(for: .milliseconds(300))
        let stoppedCount = sink.counts.total
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertEqual(sink.counts.total, stoppedCount)
        XCTAssertEqual(decoder.state, .stopped)
        decoder.start(sink: sink)
        let restartDeadline = ContinuousClock.now.advanced(by: .seconds(15))
        while sink.counts.total < stoppedCount + 3, ContinuousClock.now < restartDeadline { try await Task.sleep(for: .milliseconds(100)) }
        XCTAssertGreaterThanOrEqual(sink.counts.total, stoppedCount + 3)
        XCTAssertEqual(sink.counts.peak, 1)
    }

    @MainActor
    func testLocalUnavailableManifestReportsRetryAndStops() async throws {
        let url = try localFixture().deletingLastPathComponent().appendingPathComponent("missing.m3u8")
        let decoder = HLSFrameSource(source: try source(url), enforceTerms: false, stallTimeout: 1, retryDelay: 0.2)
        var states: [HLSFrameSource.State] = []
        decoder.onStateChange = { states.append($0) }
        decoder.start(sink: HLSCountingSink())
        defer { decoder.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !states.contains(where: { if case .retrying = $0 { true } else { false } }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertTrue(states.contains(where: { if case .retrying = $0 { true } else { false } }))
        decoder.stop()
        let stopped = states.count
        try await Task.sleep(for: .milliseconds(400))
        XCTAssertEqual(states.count, stopped, "Stopped retry loops must not reopen a stream")
        XCTAssertEqual(decoder.state, .stopped)
    }
}

final class HLSBackoffTests: XCTestCase {
    func testBackoffDoublesFromTheBaseAndCapsAtSixtySeconds() {
        XCTAssertEqual(HLSFrameSource.backoff(base: 2, failures: 1), 2)
        XCTAssertEqual(HLSFrameSource.backoff(base: 2, failures: 2), 4)
        XCTAssertEqual(HLSFrameSource.backoff(base: 2, failures: 5), 32)
        XCTAssertEqual(HLSFrameSource.backoff(base: 2, failures: 6), 60)
        XCTAssertEqual(HLSFrameSource.backoff(base: 5, failures: 30), 60)
        XCTAssertEqual(HLSFrameSource.backoff(base: 0.1, failures: 1), 0.1, accuracy: 1e-9)
    }
}
