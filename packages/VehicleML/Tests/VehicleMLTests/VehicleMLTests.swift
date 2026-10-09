import XCTest
@testable import VehicleML
import PlateKit

final class ModelRegistryTests: XCTestCase {
    func testLatestVersionSelection() throws {
        let url = URL(string: "https://example.invalid/m.mlpackage")!
        let registry = ModelRegistry(entries: [
            .init(name: "m-1", task: "plate-detection", version: "1.0.0",
                  url: url, sha256: "aa", license: "MIT", inputDescription: "img"),
            .init(name: "m-2", task: "plate-detection", version: "1.2.0",
                  url: url, sha256: "bb", license: "MIT", inputDescription: "img"),
            .init(name: "o-1", task: "plate-ocr", version: "2.0.0",
                  url: url, sha256: "cc", license: "MIT", inputDescription: "img"),
        ])
        XCTAssertEqual(registry.latest(forTask: "plate-detection")?.name, "m-2")
        XCTAssertEqual(registry.latest(forTask: "plate-ocr")?.name, "o-1")
        XCTAssertNil(registry.latest(forTask: "vehicle-detection"))
    }

    func testRegistryRoundTrip() throws {
        let url = URL(string: "https://example.invalid/m.mlpackage")!
        let registry = ModelRegistry(entries: [
            .init(name: "m", task: "t", version: "0.1", url: url, sha256: "00",
                  sourceURL: URL(string: "https://github.com/example/m")!,
                  license: "MIT", inputDescription: "IMAGE 384x640"),
        ])
        let data = try JSONEncoder().encode(registry)
        let back = try JSONDecoder().decode(ModelRegistry.self, from: data)
        XCTAssertEqual(back, registry)
    }
}
