import XCTest
@testable import PlateSync

final class BackendSelectionTests: XCTestCase {
    func testReferenceServerPortMatchesLocalServer() {
        XCTAssertEqual(SyncBackends.mirrorURL(override: nil).absoluteString, "http://127.0.0.1:8083")
    }

    func testUnsafeAndMalformedOverridesDoNotCrashOrSendCredentials() {
        for value in ["", "://", "http://example.com", "https://user:secret@example.com", "https://example.com/?token=secret", "file:///tmp/server"] {
            XCTAssertEqual(SyncBackends.mirrorURL(override: value), SyncBackends.mirrorURL(override: nil))
        }
        XCTAssertEqual(SyncBackends.mirrorURL(override: "https://mirror.example.com").host, "mirror.example.com")
        XCTAssertEqual(SyncBackends.mirrorURL(override: "http://localhost:8083").port, 8083)
    }
}
