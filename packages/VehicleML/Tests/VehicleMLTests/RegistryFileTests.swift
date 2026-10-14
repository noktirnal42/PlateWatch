import XCTest
@testable import VehicleML

/// Decodes the *actual* `models/registry.json` (when present) so a malformed
/// entry or an unresolvable latest-version selection fails CI, not production.
final class RegistryFileTests: XCTestCase {
    private var registryURL: URL? {
        // Navigate from this source file: Tests/VehicleMLTests → package → packages → repo root.
        let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent() // …/Tests/VehicleMLTests
        let repoRoot = here.deletingLastPathComponent() // …/packages/VehicleML/Tests
            .deletingLastPathComponent() // …/packages/VehicleML
            .deletingLastPathComponent() // …/packages
            .deletingLastPathComponent() // repo root
        let url = repoRoot.appendingPathComponent("models/registry.json")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func testRealRegistryDecodesAndResolvesWinners() throws {
        let url = try XCTUnwrap(registryURL, "models/registry.json not found next to the package")
        let registry = try ModelRegistry.load(bundleURL: url)
        XCTAssertFalse(registry.entries.isEmpty)
        // Every entry must carry a real SHA-256 or be a documented placeholder;
        // installability ignores placeholders.
        for entry in registry.entries {
            XCTAssertFalse(entry.sha256.isEmpty, entry.name)
            XCTAssertFalse(entry.url.absoluteString.contains("REPLACE"), entry.name)
        }
        // The Create ML plate detector (0.2.0) must win over the YOLOv8n fallback.
        XCTAssertEqual(registry.latest(forTask: "plate-detection")?.name, "plate-detector-createml-v1")
        XCTAssertEqual(registry.latest(forTask: "vehicle-detection")?.name, "vehicle-detector-yolov8n")
    }
}
