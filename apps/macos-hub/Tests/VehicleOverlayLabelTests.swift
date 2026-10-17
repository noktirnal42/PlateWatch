import PlateKit
import XCTest

final class VehicleOverlayLabelTests: XCTestCase {
    func testOrdinaryVehiclesShowBodyClassWithoutZeroFleetScore() {
        for (body, expected) in [("car", "Car"), ("truck", "Truck"), ("bus", "Bus"), ("motorcycle", "Motorcycle")] {
            let vehicle = VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 1, height: 1),
                classConfidence: 0.82, attributes: .init(bodyType: body))
            XCTAssertEqual(VehicleOverlayLabel.text(for: vehicle, fleetConfidence: 0), "\(expected) · class 82%")
            XCTAssertFalse(vehicle.vehicleClass.isFleet)
        }
    }

    func testColorIsReadableWithoutChangingFleetStatus() {
        let vehicle = VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 1, height: 1),
                                          attributes: .init(color: "blue", bodyType: "suv"))
        XCTAssertEqual(VehicleOverlayLabel.text(for: vehicle, fleetConfidence: 0), "Blue SUV")
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

    func testClassifierConfidenceRemainsVisibleWhenBodyLabelIsMissing() {
        let vehicle = VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 1, height: 1), classConfidence: 0.61)
        XCTAssertEqual(VehicleOverlayLabel.text(for: vehicle, fleetConfidence: 0), "Vehicle · class 61%")
    }

    func testCommonBodyAliasesAreReadable() {
        for (body, expected) in [("suv", "SUV"), ("van", "Van"), ("pickup_truck", "Pickup"),
                                 ("sedan", "Car"), ("sport_utility_vehicle", "SUV"),
                                 ("motorbike", "Motorcycle"), ("minivan", "Van")] {
            let vehicle = VehicleObservation(boundingBox: .init(x: 0, y: 0, width: 1, height: 1),
                classConfidence: 0.7, attributes: .init(bodyType: body))
            XCTAssertEqual(VehicleOverlayLabel.text(for: vehicle, fleetConfidence: 0), "\(expected) · class 70%")
        }
    }
}
