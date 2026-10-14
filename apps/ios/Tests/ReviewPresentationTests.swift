import XCTest
import PlateKit
import PlateSync
@testable import PlateWatch

final class ReviewPresentationTests: XCTestCase {
    func testSimulatorUsesRESTWithoutConstructingCloudKit() {
        #if targetEnvironment(simulator)
        XCTAssertTrue(AppSyncConfiguration.makeBackend() is RESTBackend)
        #endif
    }
    func testAlertMirrorDropsMutedAndDeletedEntries() {
        let first = WatchlistItem(plateText: "GOV1")
        let second = WatchlistItem(plateText: "GOV2")
        XCTAssertEqual(WatchlistNotificationMirror.plates(from: [first, second]), ["GOV1", "GOV2"])
        first.notifyEnabled = false
        XCTAssertEqual(WatchlistNotificationMirror.plates(from: [first, second]), ["GOV2"])
        XCTAssertEqual(WatchlistNotificationMirror.plates(from: [first]), [])
    }
    func testFleetInputAllowsOfficialAndVanityFormats() {
        for plate in ["D756", "12", "GOV", "AB-123", "1234567890"] {
            XCTAssertNil(FleetWatchlistInput.validationMessage(plate, existing: []), plate)
        }
    }
    func testRejectsDuplicatesAfterNormalization() {
        XCTAssertNotNil(FleetWatchlistInput.validationMessage("ab-123", existing: ["AB123"]))
    }
    func testRejectsInvalidCharactersAndLengths() {
        for plate in ["", "A", "12345678901", "AB🙂123", "AB/123", "É123", "ß123", "ＡＢ123"] {
            XCTAssertNotNil(FleetWatchlistInput.validationMessage(plate, existing: []), plate)
        }
    }
    func testShareSummaryExcludesSensitivePayloadFields() {
        let dto = SightingSubmissionDTO(capturedAt: Date(timeIntervalSince1970: 0), geohash6: "9q8yyk",
                                       exactLatitude: 37.123456, exactLongitude: -122.654321,
                                       cropHashSHA256: "private-crop-hash", cropJPEGBase64: "private-image",
                                       deviceIDHash: "private-device-id", fleetConfidence: 0.8,
                                       vehicle: .init(vehicleClass: "patrol", classConfidence: 0.9))
        let summary = SightingPresentation(submission: dto).shareText
        XCTAssertTrue(summary.contains("9q8yyk"))
        XCTAssertTrue(summary.contains("not a probability"))
        XCTAssertTrue(summary.contains("publication have not been verified"))
        for secret in ["37.123456", "122.654321", "private-crop-hash", "private-image", "private-device-id"] {
            XCTAssertFalse(summary.contains(secret))
        }
    }
}
