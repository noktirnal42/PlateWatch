import XCTest
@testable import VehicleML

final class OfflineRegistryTests: XCTestCase {
    func testBundledRegistryContainsCoreVehicleTasks() throws {
        let url = Bundle.module.url(forResource: "registry", withExtension: "json")
        XCTAssertNotNil(url)
        let data = try Data(contentsOf: XCTUnwrap(url))
        let registry = try JSONDecoder().decode(ModelRegistry.self, from: data)
        XCTAssertNotNil(registry.latest(forTask: "vehicle-detection"))
        XCTAssertNotNil(registry.latest(forTask: "vehicle-type-classification"))
        XCTAssertNotNil(registry.latest(forTask: "plate-detection"))
    }
}
