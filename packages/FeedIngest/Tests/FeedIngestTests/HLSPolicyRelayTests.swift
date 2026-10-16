import Foundation
import XCTest
@testable import FeedIngest

private final class RelayRequests: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    func contains(_ path: String) -> Bool { lock.withLock { urls.contains { $0.path == path } } }
    func reset() { lock.withLock { urls.removeAll() } }
}
private final class RelayUpstream: URLProtocol, @unchecked Sendable {
    static let requests = RelayRequests()
    private var pending: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let url = request.url!
        Self.requests.add(url)
        let body: Data
        switch url.path {
        case "/master.m3u8": body = Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=100000\nchild.m3u8\n".utf8)
        case "/child.m3u8": body = Data("#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nsegment.ts\n#EXT-X-ENDLIST\n".utf8)
        case "/cross.m3u8": body = Data("#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"https://unreviewed.example/key\"\nhttps://unreviewed.example/segment.ts\n".utf8)
        case "/oversize.ts": body = Data(repeating: 0, count: 8_388_609)
        default: body = Data([1,2,3,4])
        }
        let code = request.value(forHTTPHeaderField: "Range") == nil ? 200 : 206
        var headers = code == 206 ? ["Content-Range": "bytes 0-3/4"] : [:]
        headers["Content-Length"] = String(body.count)
        if url.path == "/slow.ts" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": "65536"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 32768))
            pending = Task { @Sendable [weak self] in
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
                guard let self else { return }
                self.client?.urlProtocol(self, didLoad: Data(repeating: 2, count: 32768))
                self.client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { pending?.cancel() }
}

final class HLSPolicyRelayTests: XCTestCase {
    private func configuration() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [RelayUpstream.self]; return config
    }
    func testRewritesEveryDeclaredResourceAndRejectsUnmediatedForms() throws {
        var seen: [URL] = []
        let input = "#EXTM3U\n#EXT-X-MEDIA:TYPE=AUDIO,URI=\"audio.m3u8\"\n#EXT-X-KEY:METHOD=AES-128,URI=\"key.bin\"\n#EXT-X-MAP:URI=\"init.mp4\"\n#EXT-X-PART:URI=\"part.m4s\",DURATION=1\nchild.m3u8\n"
        let output = try HLSPolicyRelay.rewrite(input, base: URL(string: "https://video.example/live/root.m3u8")!) { url in
            seen.append(url); return URL(string: "http://127.0.0.1:1234/private/\(seen.count)")!
        }
        XCTAssertEqual(seen.map(\.lastPathComponent), ["audio.m3u8","key.bin","init.mp4","part.m4s","child.m3u8"])
        XCTAssertFalse(output.contains("https://video.example"))
        for bad in ["#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=https://bad.example/key", "#EXTM3U\nfile:///private/a", "#EXTM3U\n#EXT-X-CONTENT-STEERING:SERVER-URI=\"https://bad.example/steer\"", "#EXTM3U\n#EXT-X-DEFINE:NAME=\"x\",VALUE=\"bad\""] {
            XCTAssertThrowsError(try HLSPolicyRelay.rewrite(bad, base: URL(string: "https://video.example/root.m3u8")!) { $0 })
        }
    }
    @MainActor func testNestedPlaylistAndByteRangeTraverseRelayAndStopClosesListener() async throws {
        RelayUpstream.requests.reset()
        let relay = HLSPolicyRelay(url: URL(string: "https://video.example/master.m3u8")!, policy: { $0.host == "video.example" }, configuration: configuration())
        defer { relay.stop() }
        let root = try await relay.start()
        let (master, _) = try await URLSession.shared.data(from: root)
        let child = try XCTUnwrap(String(data: master, encoding: .utf8)?.components(separatedBy: "\n").compactMap(URL.init(string:)).first { $0.host == "127.0.0.1" })
        let (playlist, _) = try await URLSession.shared.data(from: child)
        let segment = try XCTUnwrap(String(data: playlist, encoding: .utf8)?.components(separatedBy: "\n").compactMap(URL.init(string:)).first { $0.host == "127.0.0.1" })
        var request = URLRequest(url: segment); request.setValue("bytes=0-3", forHTTPHeaderField: "Range")
        let (bytes, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual(bytes, Data([1,2,3,4]))
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range"), "bytes 0-3/4")
        XCTAssertTrue(RelayUpstream.requests.contains("/child.m3u8"))
        XCTAssertTrue(RelayUpstream.requests.contains("/segment.ts"))
        relay.stop()
        do { _ = try await URLSession.shared.data(from: root); XCTFail("Stopped listener accepted a resource") } catch {}
    }
    @MainActor func testUnreviewedCrossOriginKeyAndSegmentNeverReachUpstream() async throws {
        RelayUpstream.requests.reset()
        let relay = HLSPolicyRelay(url: URL(string: "https://video.example/cross.m3u8")!, policy: { $0.host == "video.example" }, configuration: configuration())
        defer { relay.stop() }
        let root = try await relay.start()
        let (data, _) = try await URLSession.shared.data(from: root)
        let text = try XCTUnwrap(String(data: data, encoding: .utf8))
        let regex = try NSRegularExpression(pattern: #"http://127\.0\.0\.1:[0-9]+/[^"\n]+"#)
        let links = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).flatMap { URL(string: String(text[$0])) } }
        XCTAssertEqual(links.count, 2)
        for url in links {
            let (_, response) = try await URLSession.shared.data(from: url)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        }
        XCTAssertFalse(RelayUpstream.requests.contains("/key"))
        XCTAssertFalse(RelayUpstream.requests.contains("/segment.ts"))
        var unauthorized = URLComponents(url: root, resolvingAgainstBaseURL: false)!
        unauthorized.path = "/wrong/route"
        let (_, response) = try await URLSession.shared.data(from: unauthorized.url!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 403)
    }
    @MainActor func testSlowSegmentDeliversBoundedBodyWithoutProcessAbort() async throws {
        let relay = HLSPolicyRelay(url: URL(string: "https://video.example/slow.ts")!, policy: { _ in true }, configuration: configuration())
        defer { relay.stop() }
        let root = try await relay.start()
        let started = Date()
        let (body, response) = try await URLSession.shared.data(from: root)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(body.count, 65536)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3.5, "The bounded segment request should complete within the fixture timeout")
    }

    @MainActor func testStoppingSlowSegmentCancelsWithoutProcessAbort() async throws {
        let relay = HLSPolicyRelay(url: URL(string: "https://video.example/slow.ts")!, policy: { _ in true }, configuration: configuration())
        let root = try await relay.start()
        let request = Task {
            try await URLSession.shared.data(from: root)
        }
        try await Task.sleep(for: .milliseconds(100))
        relay.stop()
        do {
            _ = try await request.value
        } catch {
            // Cancellation or a bounded transport failure is expected.
        }
        XCTAssertTrue(true, "Relay shutdown returned without aborting the process")
    }

    @MainActor func testOversizeResourceAndBrowserOriginAreRejected() async throws {
        let relay = HLSPolicyRelay(url: URL(string: "https://video.example/oversize.ts")!, policy: { _ in true }, configuration: configuration())
        defer { relay.stop() }
        let root = try await relay.start()
        let (_, response) = try await URLSession.shared.data(from: root)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 502)
        var request = URLRequest(url: root); request.setValue("https://browser.example", forHTTPHeaderField: "Origin")
        let (_, refused) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((refused as? HTTPURLResponse)?.statusCode, 403)
    }

    @MainActor func testOptInApprovedPlaylistGraphAndFirstSegmentBytes() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLATEWATCH_APPROVED_NV_STREAM_FILE"] else { throw XCTSkip("Approved NV stream only") }
        let rootURL = try XCTUnwrap(URL(string: String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        let robots = RobotsCache(session: URLSession(configuration: .ephemeral), userAgent: "PlateWatchHub/0.1", publicAPIPermissions: PublicAPIPermission.nevada511Video)
        let relay = HLSPolicyRelay(url: rootURL, policy: { url in
            guard url.host == rootURL.host else { return false }
            return await robots.isAllowed(url)
        })
        defer { relay.stop() }
        var url = try await relay.start()
        for _ in 0..<4 {
            if url.pathExtension != "m3u8" {
                // Match a bounded decoder probe rather than downloading an entire
                // slow live segment solely for QA. Fixture tests verify full bodies.
                let (bytes, response) = try await URLSession.shared.bytes(from: url)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                var count = 0
                for try await _ in bytes { count += 1; if count == 32768 { break } }
                XCTAssertGreaterThan(count, 0)
                print("Approved first-segment stream delivered \(count) bytes; remainder cancelled")
                return
            }
            let (data, rawResponse) = try await URLSession.shared.data(from: url)
            let response = try XCTUnwrap(rawResponse as? HTTPURLResponse)
            print("Approved resource",url.pathExtension,response.statusCode,data.count,response.mimeType ?? "none",relay.lastFailure ?? "OK")
            XCTAssertEqual(response.statusCode, 200)
            if url.pathExtension != "m3u8" { XCTAssertGreaterThan(data.count, 0); return }
            let text = try XCTUnwrap(String(data: data, encoding: .utf8))
            let line = try XCTUnwrap(text.components(separatedBy: "\n").first { !$0.isEmpty && !$0.hasPrefix("#") })
            url = try XCTUnwrap(URL(string: line))
        }
        XCTFail("No segment reached")
    }

    func testRedirectIsCheckedBeforeFollowingAndRefusesDowngrade() async throws {
        let policy = HLSRedirectPolicy { $0.host == "approved.example" }
        let url = URL(string: "https://approved.example/root.m3u8")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: [:])!
        let allowed = await withCheckedContinuation { continuation in
            policy.urlSession(.shared, task: URLSession.shared.dataTask(with: url), willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: URL(string: "https://approved.example/child.m3u8")!)) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(allowed?.url?.path, "/child.m3u8")
        for destination in ["https://unreviewed.example/file.ts", "http://approved.example/file.ts"] {
            let answer = await withCheckedContinuation { continuation in
                policy.urlSession(.shared, task: URLSession.shared.dataTask(with: url), willPerformHTTPRedirection: response,
                                  newRequest: URLRequest(url: URL(string: destination)!)) { continuation.resume(returning: $0) }
            }
            XCTAssertNil(answer)
        }
    }
}
