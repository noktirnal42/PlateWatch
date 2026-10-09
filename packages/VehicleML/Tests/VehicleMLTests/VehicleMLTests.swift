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
