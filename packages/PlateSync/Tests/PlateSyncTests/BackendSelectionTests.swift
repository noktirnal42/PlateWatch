import XCTest
@testable import PlateSync

final class BackendSelectionTests: XCTestCase {
    func testExplicitReferenceServerDestinationOverridesCloudKitEntitlement() {
        XCTAssertTrue(SyncBackends.makeDefault(destination: .referenceServer) is RESTBackend)
    }

    func testReferenceServerPortMatchesLocalServer() {
        XCTAssertEqual(SyncBackends.mirrorURL(override: nil, stored: nil).absoluteString, "http://127.0.0.1:8083")
    }

    func testUnsafeAndMalformedOverridesDoNotCrashOrSendCredentials() {
        for value in ["", "://", "http://example.com", "https://user:secret@example.com", "https://example.com/?token=secret", "file:///tmp/server"] {
            XCTAssertEqual(SyncBackends.mirrorURL(override: value, stored: nil), SyncBackends.mirrorURL(override: nil, stored: nil))
        }
        XCTAssertEqual(SyncBackends.mirrorURL(override: "https://mirror.example.com").host, "mirror.example.com")
        XCTAssertEqual(SyncBackends.mirrorURL(override: "http://localhost:8083").port, 8083)
    }

    func testStoredMirrorIsUsedAfterEnvironmentAndValidated() {
        XCTAssertEqual(SyncBackends.mirrorURL(override: nil, stored: "https://mirror.example.org").host, "mirror.example.org")
        XCTAssertEqual(SyncBackends.mirrorURL(override: "https://env.example.org", stored: "https://mirror.example.org").host, "env.example.org")
        XCTAssertEqual(SyncBackends.mirrorURL(override: nil, stored: "http://evil.example.org"), SyncBackends.defaultMirrorURL)
    }

    func testSettingsRoundTripAndRefuseUnsafeURLs() throws {
        let defaults = UserDefaults(suiteName: "SyncSettingsTests-\(UUID().uuidString)")!
        XCTAssertEqual(SyncSettings.load(defaults), SyncSettings())
        try SyncSettings(destination: .referenceServer, mirrorURL: " https://mirror.example.org ").save(defaults)
        let loaded = SyncSettings.load(defaults)
        XCTAssertEqual(loaded.destination, .referenceServer)
        XCTAssertEqual(loaded.mirrorURL, "https://mirror.example.org")
        XCTAssertThrowsError(try SyncSettings(destination: .automatic, mirrorURL: "http://example.com").save(defaults))
        XCTAssertEqual(SyncSettings.load(defaults).mirrorURL, "https://mirror.example.org", "failed save must not change stored value")
        try SyncSettings(destination: .automatic, mirrorURL: "  ").save(defaults)
        XCTAssertNil(SyncSettings.load(defaults).mirrorURL)
    }

    func testConfiguredReferenceServerBackendIsREST() {
        XCTAssertTrue(SyncBackends.makeConfigured(settings: SyncSettings(destination: .referenceServer, mirrorURL: "https://m.example.org")) is RESTBackend)
    }

    func testHeartbeatCapsFeedIDsSoLargeHubsFitTheServerBodyLimit() throws {
        let ids = (0..<1_300).map { _ in UUID() }
        let beat = PresenceHeartbeat(sessionID: "session-0000000000000001", platform: "macOS-hub", feedIDs: ids, activeProcessing: true)
        XCTAssertEqual(beat.feedIDs.count, PresenceHeartbeat.maxFeedIDs)
        XCTAssertLessThan(try JSONEncoder().encode(beat).count, 16 * 1024, "must fit Vapor's default 16 KB request body")
    }
}
