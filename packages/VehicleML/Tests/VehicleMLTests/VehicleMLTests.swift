import XCTest
@testable import VehicleML
import PlateKit

final class ModelRegistryTests: XCTestCase {
    func testLatestVersionSelection() throws {
        let url = URL(string: "https://example.invalid/m.mlpackage")!
        let registry = ModelRegistry(entries: [
            .init(name: "m-1", task: "plate-detection", version: "1.0.0",
                  url: url, sha256: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", license: "MIT", inputDescription: "img"),
            .init(name: "m-2", task: "plate-detection", version: "1.2.0",
                  url: url, sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", license: "MIT", inputDescription: "img"),
            .init(name: "o-1", task: "plate-ocr", version: "2.0.0",
                  url: url, sha256: "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc", license: "MIT", inputDescription: "img"),
        ])
        XCTAssertEqual(registry.latest(forTask: "plate-detection")?.name, "m-2")
        XCTAssertEqual(registry.latest(forTask: "plate-ocr")?.name, "o-1")
        XCTAssertNil(registry.latest(forTask: "vehicle-detection"))
    }

    func testRegistryRoundTrip() throws {
        let url = URL(string: "https://example.invalid/m.mlpackage")!
        let registry = ModelRegistry(entries: [
            .init(name: "m", task: "t", version: "0.1", url: url, sha256: "0000000000000000000000000000000000000000000000000000000000000000",
                  sourceURL: URL(string: "https://github.com/example/m")!,
                  license: "MIT", inputDescription: "IMAGE 384x640"),
        ])
        let data = try JSONEncoder().encode(registry)
        let back = try JSONDecoder().decode(ModelRegistry.self, from: data)
        XCTAssertEqual(back, registry)
    }
}

final class MultiFrameFusorTests: XCTestCase {

    private func frame(with plates: [(text: String, conf: Double, box: NormalizedBox)]) -> DetectionFrame {
        let vehicles = plates.map { p in
            VehicleObservation(
                boundingBox: p.box,
                plates: [PlateObservation(boundingBox: p.box, candidates: [Plate(text: p.text, confidence: p.conf)])])
        }
        return DetectionFrame(timestamp: Date(), imageSize: .init(width: 1920, height: 1080),
                              vehicles: vehicles)
    }

    private let boxA = NormalizedBox(x: 0.4, y: 0.6, width: 0.12, height: 0.05)

    func testSingleReadBelowMinFramesNotReported() async {
        let fusor = MultiFrameFusor()
        let readings = await fusor.ingest(frame(with: [("1ABC234", 0.9, boxA)]))
        XCTAssertTrue(readings.isEmpty, "single-frame reads must not surface")
    }

    func testStablePlateAcrossFramesFuses() async {
        let fusor = MultiFrameFusor()
        _ = await fusor.ingest(frame(with: [("1ABC234", 0.5, boxA)]))
        _ = await fusor.ingest(frame(with: [("1ABC234", 0.5, boxA)]))
        let readings = await fusor.ingest(frame(with: [("1ABC234", 0.5, boxA)]))
        XCTAssertEqual(readings.first?.text, "1ABC234")
        XCTAssertEqual(readings.first?.supportingFrames, 3)
        // 1 − (1−0.5)³ = 0.875 — multi-frame evidence beats any single read.
        XCTAssertEqual(readings.first?.confidence ?? 0, 0.875, accuracy: 0.001)
    }

    func testNearMissOCRVariantVotesMerge() async {
        let fusor = MultiFrameFusor()
        _ = await fusor.ingest(frame(with: [("1ABC234", 0.5, boxA)]))
        _ = await fusor.ingest(frame(with: [("1ABC23A", 0.5, boxA)]))   // 4↔A misread
        let readings = await fusor.ingest(frame(with: [("1ABC234", 0.6, boxA)]))
        XCTAssertEqual(readings.first?.text, "1ABC234")
        XCTAssertEqual(readings.first?.supportingFrames, 3)
    }

    func testSeparateTracksStaySeparate() async {
        let fusor = MultiFrameFusor()
        let boxB = NormalizedBox(x: 0.6, y: 0.8, width: 0.12, height: 0.05)
        for _ in 0..<3 {
            _ = await fusor.ingest(frame(with: [("AAA111", 0.8, boxA), ("BBB222", 0.8, boxB)]))
        }
        let readings = await fusor.ingest(frame(with: [("AAA111", 0.8, boxA), ("BBB222", 0.8, boxB)]))
        XCTAssertEqual(Set(readings.map(\.text)), ["AAA111", "BBB222"])
    }

    func testTrackExpiry() async {
        let fusor = MultiFrameFusor(config: .init(trackIoUThreshold: 0.2, maxSilence: 2,
                                                  editDistanceMerge: 1, minFusedConfidence: 0.25))
        _ = await fusor.ingest(frame(with: [("AAA111", 0.8, boxA)]))
        _ = await fusor.ingest(frame(with: [("AAA111", 0.8, boxA)]))
        // 3 empty frames → expired; a later single read must not report.
        for _ in 0..<3 { _ = await fusor.ingest(frame(with: [])) }
        let readings = await fusor.ingest(frame(with: [("AAA111", 0.9, boxA)]))
        XCTAssertTrue(readings.isEmpty)
    }
}

final class RegistryPlaceholderTests: XCTestCase {
    func testPlaceholderEntriesAreNeverSelected() {
        let url = URL(string: "https://example.invalid/m.mlpackage")!
        let real = String(repeating: "ab", count: 32)
        let registry = ModelRegistry(entries: [
            .init(name: "ocr-placeholder", task: "plate-ocr", version: "9.0.0",
                  url: url, sha256: "REPLACE_AT_CONVERSION_TIME", license: "MIT", inputDescription: "img"),
            .init(name: "ocr-real", task: "plate-ocr", version: "1.0.0",
                  url: url, sha256: real, license: "MIT", inputDescription: "img"),
        ])
        XCTAssertEqual(registry.latest(forTask: "plate-ocr")?.name, "ocr-real")
        let onlyPlaceholder = ModelRegistry(entries: [registry.entries[0]])
        XCTAssertNil(onlyPlaceholder.latest(forTask: "plate-ocr"))
    }
}

// MARK: - Model artifacts and developer overrides

final class ModelArtifactTests: XCTestCase {

    private func entry(url: String, format: String? = nil) -> ModelRegistryEntry {
        ModelRegistryEntry(name: "plate-detector-createml", task: "plate-detection", version: "0.2.0",
                           url: URL(string: url)!, sha256: String(repeating: "a", count: 64),
                           license: "CC BY 2.0 data", inputDescription: "IMAGE", format: format)
    }

    /// CoreML compiles by extension; the old temp name ("<name>.download") could never compile.
    func testArtifactExtensionFollowsFormatThenURL() {
        XCTAssertEqual(entry(url: "https://x/m.mlmodel").artifactExtension, "mlmodel")
        XCTAssertEqual(entry(url: "https://x/m.mlpackage").artifactExtension, "mlpackage")
        XCTAssertEqual(entry(url: "https://x/m.zip", format: "mlmodel").artifactExtension, "mlmodel")
        XCTAssertEqual(entry(url: "https://x/m.mlmodel", format: "mlpackage").artifactExtension, "mlpackage")
        XCTAssertEqual(entry(url: "https://x/download?id=3").artifactExtension, "mlmodel", "unknown → single file")
    }

    func testRegistryEntryWithoutFormatStillDecodes() throws {
        let json = """
        {"schemaVersion":1,"entries":[{"name":"n","task":"plate-detection","version":"0.1.0",
        "url":"https://x/n.mlpackage","sha256":"\(String(repeating: "b", count: 64))","license":"MIT","inputDescription":"IMAGE"}]}
        """
        let reg = try JSONDecoder().decode(ModelRegistry.self, from: Data(json.utf8))
        XCTAssertNil(reg.entries[0].format)
        XCTAssertEqual(reg.entries[0].artifactExtension, "mlpackage")
    }

    func testLocalOverridePrefersCompiledThenPackageThenFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pw-local-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertNil(ModelManager.localModelURL(forTask: "plate-detection", in: dir))
        func touch(_ name: String) { FileManager.default.createFile(atPath: dir.appendingPathComponent(name).path, contents: Data()) }
        touch("plate-detection.mlmodel")
        XCTAssertEqual(ModelManager.localModelURL(forTask: "plate-detection", in: dir)?.lastPathComponent, "plate-detection.mlmodel")
        touch("plate-detection.mlpackage")
        XCTAssertEqual(ModelManager.localModelURL(forTask: "plate-detection", in: dir)?.lastPathComponent, "plate-detection.mlpackage")
        touch("plate-detection.mlmodelc")
        XCTAssertEqual(ModelManager.localModelURL(forTask: "plate-detection", in: dir)?.lastPathComponent, "plate-detection.mlmodelc")
        XCTAssertNil(ModelManager.localModelURL(forTask: "vehicle-detection", in: dir), "per-task, never another task's file")
    }

    func testDefaultLocalDirectoryIsUnderTheCache() {
        let cfg = ModelManager.Config(registryURL: URL(string: "https://x/r.json")!,
                                      cacheDirectory: URL(fileURLWithPath: "/tmp/cache"))
        XCTAssertEqual(cfg.localModelsDirectory.path, "/tmp/cache/Local")
    }
}
