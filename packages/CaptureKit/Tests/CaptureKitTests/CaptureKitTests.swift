import XCTest
@testable import CaptureKit

final class CaptureConfigurationTests: XCTestCase {
    func testPresetsHaveSanePhysics() {
        XCTAssertEqual(CaptureConfiguration.dashcam.minimumShutterSeconds, 0.001, accuracy: 0.0001)
        XCTAssertGreaterThanOrEqual(CaptureConfiguration.handheld.analyzeEveryNthFrame, 2)
        XCTAssertTrue(CaptureConfiguration.handheld.preferTelephoto)
    }
}
