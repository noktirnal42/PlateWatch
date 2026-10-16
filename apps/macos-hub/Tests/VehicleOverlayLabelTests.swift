import PlateKit
import XCTest

final class VehicleOverlayLabelTests: XCTestCase {
    func testOrdinaryVehiclesShowBodyClassWithoutZeroFleetScore() {
        for (body, expected) in [("car", "Car"), ("truck", "Truck"), ("bus", "Bus"), ("motorcycle", "Motorcycle")] {
            let vehicle = VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 1, height: 1),
                attributes: .init(bodyType: body))
            XCTAssertEqual(VehicleOverlayLabel.text(for: vehicle, fleetConfidence: 0), expected)
            XCTAssertFalse(vehicle.vehicleClass.isFleet)
        }
    }
    func testFleetLabelSeparatesBodyTypeAndFleetScore() {
        let vehicle = VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 1, height: 1),
            vehicleClass: .patrol, attributes: .init(bodyType: "car"))
        XCTAssertEqual(VehicleOverlayLabel.text(for: vehicle, fleetConfidence: 0.85), "Car · Patrol · fleet 85%")
        XCTAssertEqual(VehicleOverlayLabel.text(for: vehicle, fleetConfidence: .nan), "Car · Patrol · fleet 0%")
    }
    func testMissingClassUsesNeutralVehicleLabel() {
        let vehicle = VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(VehicleOverlayLabel.text(for: vehicle, fleetConfidence: 0), "Vehicle")
    }
}
