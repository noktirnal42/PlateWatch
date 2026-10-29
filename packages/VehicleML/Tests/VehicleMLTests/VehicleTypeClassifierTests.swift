import XCTest
@testable import VehicleML

final class VehicleTypeClassifierTests: XCTestCase {
    func testNormalizesSupportedVehicleLabels() {
        let cases = [
            ("sedan", "car"), ("sport_utility_vehicle", "suv"),
            ("pickup-truck", "pickup truck"), ("mini van", "van"),
            ("motorbike", "motorcycle"), ("coach bus", "bus"), ("lorry", "truck")
        ]
        for (label, expected) in cases {
            XCTAssertEqual(VehicleTypeClassifierStage.bodyType(for: label), expected)
        }
    }

    func testIgnoresNonVehicleLabels() {
        XCTAssertNil(VehicleTypeClassifierStage.bodyType(for: "bicycle"))
        XCTAssertNil(VehicleTypeClassifierStage.bodyType(for: "person"))
    }
}
