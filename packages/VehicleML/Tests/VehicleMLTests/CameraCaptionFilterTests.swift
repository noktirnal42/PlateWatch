import PlateKit
import XCTest
@testable import VehicleML

final class CameraCaptionFilterTests: XCTestCase {
    func testFireStationCameraTitleAndTimestampCannotSupplyMarkings() {
        let lines = [
            SceneTextObservation(text: "Crook County - Juniper Canyon Fire Station", boundingBox: .init(x: 0.01, y: 0.01, width: 0.9, height: 0.06), confidence: 0.99),
            SceneTextObservation(text: "Updated: Oct 14 2026 9:56 PM", boundingBox: .init(x: 0.01, y: 0.08, width: 0.6, height: 0.04), confidence: 0.99)
        ]
        let filtered = lines.filter { !CameraCaptionFilter.isInCaptionBand($0.boundingBox) }
        XCTAssertTrue(filtered.isEmpty)
        XCTAssertFalse(SceneTextHeuristics.parse(filtered).hasFleetKeyword)
    }

    func testCenterVehicleDoorTextSurvivesAndBottomOverlayDoesNot() {
        XCTAssertFalse(CameraCaptionFilter.isInCaptionBand(.init(x: 0.4, y: 0.4, width: 0.2, height: 0.08)))
        XCTAssertTrue(CameraCaptionFilter.isInCaptionBand(.init(x: 0.1, y: 0.94, width: 0.8, height: 0.04)))
        XCTAssertFalse(AnalysisContext().suppressCameraCaptions, "Local/handheld inputs retain their full OCR region")
    }
}
