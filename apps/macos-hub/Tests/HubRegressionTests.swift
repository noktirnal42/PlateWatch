import ImageIO
import CryptoKit
import CoreImage
import CoreVideo
import FeedIngest
import Foundation
import PlateKit
import XCTest

private struct StubResponse: Sendable {
    var status = 200
    var body = Data()
    var delay: Duration = .zero
}
private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: @Sendable (URLRequest) -> StubResponse = { _ in .init() }
    private var requests: [URLRequest] = []
    func reset(_ handler: @escaping @Sendable (URLRequest) -> StubResponse) {
        lock.lock(); defer { lock.unlock() }
        self.handler = handler; requests = []
    }
    func response(_ request: URLRequest) -> StubResponse {
        lock.lock(); requests.append(request); let handler = self.handler; lock.unlock()
        return handler(request)
    }
    func count(path: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return requests.filter { $0.url?.path == path }.count
    }
}
private final class HubStubProtocol: URLProtocol, @unchecked Sendable {
    static let state = StubState()
    private var work: Task<Void, Never>?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = Self.state.response(request)
        work = Task {
            do { try await Task.sleep(for: response.delay) } catch { return }
            guard !Task.isCancelled else { return }
            let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: "HTTP/1.1", headerFields: [:])!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: response.body)
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() { work?.cancel() }
}

final class HubRegressionTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HubStubProtocol.self]
        return URLSession(configuration: config)
    }
    private func source(_ path: String) throws -> PublicFeedSource {
        try .init(name: path, url: URL(string: "https://camera.example\(path)")!, kind: .snapshotJPEG,
                  refreshInterval: 60, geohash6: "9q8yyk", citation: .init(sourceType: .openDataPortal),
                  terms: .init(licenseClass: .publicDomain, termsURL: URL(string: "https://camera.example/terms"),
                               termsReadOn: Date(), automatedUseAllowed: true))
    }
    @MainActor private func eventually(_ predicate: () -> Bool) async -> Bool {
        for _ in 0..<600 {
            if predicate() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    @MainActor func testRobotsFailureMarksAllSourcesWithoutImageRequests() async throws {
        HubStubProtocol.state.reset { _ in .init(status: 500) }
        let sources = try (0..<20).map { try source("/cam\($0).jpg") }
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        runner.start(catalogue: .init(sources: sources)) { _, _ in XCTFail("Refused host must not reach analysis") }
        XCTAssertTrue(runner.sourceStates.values.allSatisfy { $0 == .checking })
        let finished = await eventually { runner.sourceStates.values.allSatisfy { if case .policyUnavailable = $0 { true } else { false } } }
        XCTAssertTrue(finished)
        XCTAssertEqual(runner.runningCount, 0)
        XCTAssertTrue(runner.status.contains("20 policy lookups retrying"))
        XCTAssertEqual(HubStubProtocol.state.count(path: "/robots.txt"), 3)
        for source in sources { XCTAssertEqual(HubStubProtocol.state.count(path: source.url.path), 0) }
    }

    @MainActor func testManualRefreshRecoversCachedPolicyFailureAndRestartsPolling() async throws {
        HubStubProtocol.state.reset { _ in .init(status: 500) }
        let camera = try source("/camera.jpg")
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        runner.start(catalogue: .init(sources: [camera])) { _, _ in }
        let failed = await eventually { if case .policyUnavailable = runner.sourceStates[camera.id] { true } else { false } }
        XCTAssertTrue(failed)
        HubStubProtocol.state.reset { request in
            .init(body: request.url?.path == "/robots.txt" ? Data("User-agent: *\nDisallow: /private/\n".utf8) : Data([0xFF, 0xD8, 0xFF]))
        }
        _ = try await runner.fetchPreview(of: camera, retryFailedPolicy: true)
        let resumed = await eventually { runner.sourceStates[camera.id] == .polling }
        XCTAssertTrue(resumed)
        XCTAssertEqual(HubStubProtocol.state.count(path: "/robots.txt"), 1)
    }

    @MainActor func testSuccessfulManualPreviewClearsCameraFailureDiagnostic() async throws {
        HubStubProtocol.state.reset { request in
            request.url?.path == "/robots.txt" ? .init(body: Data()) : .init(status: 503)
        }
        let camera = try source("/camera.jpg")
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        runner.start(catalogue: .init(sources: [camera])) { _, _ in }
        let failed = await eventually { if case .imageUnavailable = runner.sourceStates[camera.id] { true } else { false } }
        XCTAssertTrue(failed)
        HubStubProtocol.state.reset { request in
            .init(body: request.url?.path == "/robots.txt" ? Data() : Data([0xFF, 0xD8, 0xFF]))
        }
        _ = try await runner.fetchPreview(of: camera, retryFailedPolicy: true)
        XCTAssertEqual(runner.sourceStates[camera.id], .polling)
        XCTAssertNotNil(runner.lastReceivedAt[camera.id])
    }

    @MainActor func testCanonicalUserAgentWorksForPolicyAndImageRequests() async throws {
        let expected = "PlateWatchHub/0.1 (+https://github.com/noktirnal42/PlateWatch)"
        XCTAssertEqual(FeedRunner.userAgent, expected)
        HubStubProtocol.state.reset { request in
            guard request.value(forHTTPHeaderField: "User-Agent") == expected else { return .init(status: 403) }
            return .init(body: request.url?.path == "/robots.txt" ? Data() : Data([0xFF, 0xD8, 0xFF]))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HubStubProtocol.self]
        config.httpAdditionalHeaders = ["User-Agent": FeedRunner.userAgent]
        let runner = FeedRunner(session: URLSession(configuration: config), throttleInterval: 0)
        let camera = try source("/camera.jpg")
        let data = try await runner.fetchPreview(of: camera)
        XCTAssertEqual(data, Data([0xFF, 0xD8, 0xFF]))
    }

    @MainActor func testPathRefusalDoesNotBlockAllowedSibling() async throws {
        HubStubProtocol.state.reset { request in
            .init(body: request.url?.path == "/robots.txt" ? Data("User-agent: *\nDisallow: /private/\n".utf8) : Data([0xFF, 0xD8, 0xFF]))
        }
        let blocked = try source("/private/cam.jpg"), allowed = try source("/public/cam.jpg")
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        runner.start(catalogue: .init(sources: [blocked, allowed])) { _, _ in }
        let fetched = await eventually { HubStubProtocol.state.count(path: allowed.url.path) == 1 }
        XCTAssertTrue(fetched)
        XCTAssertEqual(runner.sourceStates[blocked.id], .blockedByRobots)
        XCTAssertEqual(runner.runningCount, 1)
        XCTAssertEqual(HubStubProtocol.state.count(path: blocked.url.path), 0)
        XCTAssertEqual(HubStubProtocol.state.count(path: "/robots.txt"), 1)
    }

    @MainActor func testVideoTransportIsNotSentToSnapshotPoller() async throws {
        HubStubProtocol.state.reset { _ in .init(body: Data()) }
        var camera = try source("/video.m3u8")
        camera.kind = .hls
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        runner.start(catalogue: .init(sources: [camera])) { _, _ in XCTFail("HLS is not a JPEG") }
        let stopped = await eventually { runner.sourceStates[camera.id] == .suspended }
        XCTAssertTrue(stopped)
        XCTAssertEqual(runner.runningCount, 0)
        XCTAssertEqual(HubStubProtocol.state.count(path: camera.url.path), 0)
    }

    @MainActor func testApprovingHLSDoesNotDecodeUnselectedStreams() async throws {
        HubStubProtocol.state.reset { _ in .init(body: Data()) }
        var camera = try source("/camera.m3u8")
        camera.kind = .hls
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        runner.start(catalogue: .init(sources: [camera]), analyse: { _, _ in }, analyseVideoFrame: { _, _ in XCTFail("Unselected stream decoded") })
        let ready = await eventually { runner.sourceStates[camera.id] == .videoIdle }
        XCTAssertTrue(ready)
        XCTAssertEqual(runner.runningCount, 0)
        XCTAssertEqual(HubStubProtocol.state.count(path: camera.url.path), 0)
    }
    @MainActor func testStopDuringPreflightCannotRestartPolling() async throws {
        HubStubProtocol.state.reset { _ in .init(body: Data(), delay: .milliseconds(80)) }
        let camera = try source("/camera.jpg")
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        runner.start(catalogue: .init(sources: [camera])) { _, _ in XCTFail("Old run resumed") }
        try await Task.sleep(for: .milliseconds(10))
        runner.stop()
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(runner.runningCount, 0)
        XCTAssertTrue(runner.sourceStates.isEmpty)
        XCTAssertEqual(HubStubProtocol.state.count(path: camera.url.path), 0)
    }

    @MainActor func testLocalBlockSkipsPollingAndPreviewUntilUnblocked() async throws {
        HubStubProtocol.state.reset { request in
            .init(body: request.url?.path == "/robots.txt" ? Data() : Data([0xFF, 0xD8, 0xFF]))
        }
        let camera = try source("/camera.jpg")
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        runner.start(catalogue: .init(sources: [camera]), blockedIDs: [camera.id]) { _, _ in }
        XCTAssertEqual(runner.state(of: camera).kind, .userBlocked)
        do { _ = try await runner.fetchPreview(of: camera); XCTFail("Blocked preview must fail") }
        catch { XCTAssertTrue(error is FeedRunner.PreviewError) }
        XCTAssertEqual(HubStubProtocol.state.count(path: "/robots.txt"), 0)
        XCTAssertEqual(HubStubProtocol.state.count(path: camera.url.path), 0)
        runner.setBlocked(camera.id, blocked: false)
        let fetched = await eventually { HubStubProtocol.state.count(path: camera.url.path) == 1 }
        XCTAssertTrue(fetched)
        runner.setBlocked(camera.id, blocked: true)
        XCTAssertEqual(runner.runningCount, 0)
        XCTAssertEqual(runner.sourceStates[camera.id], .blockedByUser)
    }

    @MainActor func testBlockingCancelsInFlightPreview() async throws {
        HubStubProtocol.state.reset { request in
            .init(body: request.url?.path == "/robots.txt" ? Data() : Data([0xFF, 0xD8, 0xFF]),
                  delay: request.url?.path == "/robots.txt" ? .zero : .seconds(1))
        }
        let camera = try source("/camera.jpg")
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        let preview = Task { try await runner.fetchPreview(of: camera) }
        let started = await eventually { HubStubProtocol.state.count(path: camera.url.path) == 1 }
        XCTAssertTrue(started)
        runner.setBlocked(camera.id, blocked: true)
        do { _ = try await preview.value; XCTFail("Blocked image must not be delivered") } catch {}
    }

    @MainActor func testPreviewReportsUnavailableImage() async throws {
        HubStubProtocol.state.reset { request in .init(status: request.url?.path == "/robots.txt" ? 200 : 404) }
        let runner = FeedRunner(session: session(), throttleInterval: 0)
        defer { runner.stop() }
        do { _ = try await runner.fetchPreview(of: source("/gone.jpg")); XCTFail("Missing feed should fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("HTTP 404")) }
    }

    @MainActor func testBlockAndFavoritePersistIndependently() throws {
        let name = "PlateWatchHubTests-\(UUID())", id = UUID()
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let preferences = FeedFavorites(defaults: defaults)
        preferences.toggle(id); preferences.toggleBlocked(id)
        let reloaded = FeedFavorites(defaults: defaults)
        XCTAssertTrue(reloaded.contains(id)); XCTAssertTrue(reloaded.isBlocked(id))
        reloaded.toggleBlocked(id)
        XCTAssertTrue(reloaded.contains(id)); XCTAssertFalse(reloaded.isBlocked(id))
        XCTAssertFalse(FeedFavorites(defaults: defaults).isBlocked(id))
    }

    func testThrottleCancellationDoesNotGrantPermission() async throws {
        let throttle = HostThrottle(interval: 0.05)
        let first = await throttle.acquire(host: "example")
        XCTAssertTrue(first)
        let waiting = Task { await throttle.acquire(host: "example") }
        await Task.yield(); waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertFalse(cancelled)
        let next = await throttle.acquire(host: "example", interactive: true)
        XCTAssertTrue(next)
    }

    @MainActor func testAuditFailureRemainsVisibleWhenQueueSucceeds() async {
        HubStubProtocol.state.reset { request in .init(status: request.url?.path.hasSuffix("audit") == true ? 503 : 200, body: Data("[]".utf8)) }
        let client = ModerationClient(baseURL: URL(string: "https://moderator.example")!, token: "test-only-token", session: session())
        let store = ModerationStore(client: client)
        await store.refresh()
        XCTAssertNil(store.queueError)
        XCTAssertTrue(store.auditError?.contains("503") == true)
        XCTAssertTrue(store.audit.isEmpty)
        XCTAssertFalse(store.busy)
    }

    @MainActor func testAuditLoadsFractionalDatesAndDoesNotCollapseDuplicates() async {
        let json = #"[{"createdAt":"2026-10-14T23:00:00.123Z","action":"takedown.dismiss","target":"test"},{"createdAt":"2026-10-14T23:00:00.123Z","action":"takedown.dismiss","target":"test"}]"#
        HubStubProtocol.state.reset { request in .init(body: Data((request.url?.path.hasSuffix("audit") == true ? json : "[]").utf8)) }
        let store = ModerationStore(client: .init(baseURL: URL(string: "https://moderator.example")!, token: "test-only-token", session: session()))
        await store.refresh()
        XCTAssertNil(store.auditError)
        XCTAssertEqual(store.audit.count, 2)
        XCTAssertNotEqual(store.audit.first?.id, store.audit.last?.id)
        XCTAssertNotNil(store.audit.first?.createdAt)
    }
}

final class HubRecoveryRegressionTests: XCTestCase {
    @MainActor func testBrowserDefaultsAndRelaunchPersistence() throws {
        let domain = "PlateWatchTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let browser = FeedBrowserState(defaults: defaults)
        XCTAssertTrue(browser.ascending, "A fresh install must retain ascending order")
        browser.ascending = false
        browser.tab = .favorites
        browser.query = "Test camera"
        browser.selected = [UUID()]
        browser.save()
        let restored = FeedBrowserState(defaults: defaults)
        XCTAssertFalse(restored.ascending, "Explicit descending order must survive relaunch")
        XCTAssertEqual(restored.tab, .favorites)
        XCTAssertEqual(restored.query, browser.query)
        XCTAssertEqual(restored.selected, browser.selected)
    }

    func testEvidenceConversionSupportsPackedAndPlanarFrames() throws {
        for format in [kCVPixelFormatType_32BGRA, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange] {
            var buffer: CVPixelBuffer?
            XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 32, 24, format,
                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
            let frame = try XCTUnwrap(buffer)
            // Synthetic solid-red frame; conversion must preserve colour, not
            // merely produce an image of the right dimensions from YUV bytes.
            CIContext().render(CIImage(color: CIColor(red: 1, green: 0, blue: 0))
                .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 24)), to: frame)
            let source = EvidenceCrop.SourceFrame(pixelBuffer: frame)
            let image = try XCTUnwrap(source.image)
            XCTAssertEqual(image.width, 32)
            XCTAssertEqual(image.height, 24)
            XCTAssertTrue(image === source.image)
            var rgba = [UInt8](repeating: 0, count: 4)
            CIContext().render(CIImage(cgImage: image), toBitmap: &rgba, rowBytes: 4,
                bounds: CGRect(x: 16, y: 12, width: 1, height: 1), format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB())
            XCTAssertGreaterThan(rgba[0], 200)
            XCTAssertLessThan(rgba[1], 40)
            XCTAssertLessThan(rgba[2], 40)
        }
        XCTAssertNil(EvidenceCrop.SourceFrame(pixelBuffer: nil).image)
    }
}


final class EvidenceCropRegressionTests: XCTestCase {
    private func source() throws -> EvidenceCrop.SourceFrame {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 320, 240, kCVPixelFormatType_32BGRA, nil, &buffer), kCVReturnSuccess)
        let frame = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: CIColor(red: 0.2, green: 0.5, blue: 0.9)).cropped(to: CGRect(x: 0, y: 0, width: 320, height: 240)), to: frame)
        return .init(pixelBuffer: frame)
    }
    func testNewEvidenceEncodesBoundedJPEGAndCorrectDigest() throws {
        let vehicle = VehicleObservation(boundingBox: .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6))
        let output = try XCTUnwrap(EvidenceCrop.make(source: try source(), vehicle: vehicle, others: [vehicle]))
        XCTAssertLessThanOrEqual(output.jpegData.count, EvidenceCrop.maxBytes)
        XCTAssertNotNil(CGImageSourceCreateWithData(output.jpegData as CFData, nil))
        XCTAssertEqual(output.sha256Hex, SHA256.hash(data: output.jpegData).map { String(format: "%02x", $0) }.joined())
        XCTAssertEqual(Data(base64Encoded: output.base64), output.jpegData)
    }
    func testIntrudingVehicleOmitsImageRatherThanExposingItsPlate() throws {
        let target = VehicleObservation(boundingBox: .init(x: 0.1, y: 0.2, width: 0.7, height: 0.6))
        let other = VehicleObservation(boundingBox: .init(x: 0.5, y: 0.4, width: 0.3, height: 0.3))
        XCTAssertNil(EvidenceCrop.make(source: try source(), vehicle: target, others: [target, other]))
    }
    func testInvalidOrOffFrameBoxesCannotProduceEvidence() throws {
        for box in [NormalizedBox(x: .nan, y: 0, width: 1, height: 1), .init(x: 2, y: 2, width: 0.1, height: 0.1), .init(x: 0, y: 0, width: 0, height: 1)] {
            let vehicle = VehicleObservation(boundingBox: box)
            XCTAssertNil(EvidenceCrop.make(source: try source(), vehicle: vehicle, others: [vehicle]))
        }
    }
}


final class HLSPreviewRegressionTests: XCTestCase {
    @MainActor func testOptInExistingFavoritePreviews() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLATEWATCH_FAVORITES_AUDIT_PATH"] else { throw XCTSkip("Opt-in saved approved favorites") }
        let catalogue = try FeedCatalogue.load(from: URL(fileURLWithPath: path))
        let runner = FeedRunner()
        defer { runner.stop() }
        for source in catalogue.sources where source.mayBeAnalysed {
            do {
                let data = try await runner.fetchPreview(of: source, retryFailedPolicy: true)
                print("FAVORITE PREVIEW OK | \(source.name) | \(source.url.host ?? "") | \(data.count) bytes")
            } catch {
                print("FAVORITE PREVIEW FAILED | \(source.name) | \(source.url.host ?? "") | \(error.localizedDescription)")
            }
        }
    }
    @MainActor func testOptInApprovedNV511Stream() async throws {
        guard let path = ProcessInfo.processInfo.environment["PLATEWATCH_APPROVED_NV_STREAM_FILE"] else { throw XCTSkip("Opt-in human-approved NV511 media") }
        let raw = try String(contentsOfFile: path, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let url = try XCTUnwrap(URL(string: raw))
        XCTAssertTrue(url.host?.hasSuffix(".its.nv.gov") == true)
        let cache = RobotsCache(session: URLSession(configuration: .ephemeral), userAgent: FeedRunner.userAgent, publicAPIPermissions: PublicAPIPermission.nevada511Video)
        let decision = await cache.decision(for: url)
        XCTAssertTrue(decision.isAllowed, "Real-stream verification must respect current robots policy")
        guard decision.isAllowed else { return }
        let source = try PublicFeedSource(name: "Approved NV511 transport verification", url: url, kind: .hls,
            refreshInterval: 300, geohash6: "9r4b8x", citation: .init(sourceType: .openDataPortal, url: NV511Cameras.endpoint),
            terms: .init(licenseClass: .keyed, termsURL: NV511Cameras.apiDocs, termsReadOn: Date(), attribution: "Nevada 511 / NDOT; owner confirmed review 2026-10-15", automatedUseAllowed: true))
        let jpeg = try await FeedRunner.hlsPreviewFrame(source: source, timeout: 25)
        XCTAssertTrue(jpeg.starts(with: [0xFF, 0xD8]))
        print("Approved NV511 real HLS preview decoded successfully (\(jpeg.count) bytes; frame not saved)")
    }
    @MainActor func testOrdinaryHLSPreviewAndCancellation() async throws {
        guard let raw = ProcessInfo.processInfo.environment["PLATEWATCH_HLS_FIXTURE_URL"],
              let url = URL(string: raw), url.host == "127.0.0.1" else { throw XCTSkip("Opt-in loopback HLS fixture") }
        let source = try PublicFeedSource(name: "Synthetic HLS", url: url, kind: .hls, refreshInterval: 1,
            geohash6: "9q8yyk", citation: .init(sourceType: .openDataPortal, url: url),
            terms: .init(licenseClass: .publicDomain, termsURL: url, termsReadOn: Date(), automatedUseAllowed: true))
        let jpeg = try await FeedRunner.hlsPreviewFrame(source: source)
        XCTAssertTrue(jpeg.starts(with: [0xFF, 0xD8]))
        XCTAssertNotNil(CGImageSourceCreateWithData(jpeg as CFData, nil))
        let task = Task { try await FeedRunner.hlsPreviewFrame(source: source) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled preview returned media") } catch is CancellationError {} catch { XCTFail("Expected cancellation, got \(error)") }
    }
}
