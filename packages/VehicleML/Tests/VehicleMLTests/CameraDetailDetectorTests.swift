import CoreImage
import CoreML
import CoreVideo
import ImageIO
import PlateKit
import XCTest
@testable import VehicleML

final class CameraDetailDetectorTests: XCTestCase {
    func testProjectionPreservesTopLeftCoordinatesAcrossOverlappingTiles() {
        let region = CameraDetailDetectorStage.regions[3]
        let mapped = CameraDetailDetectorStage.project(.init(x: 0.5, y: 0.25, width: 0.2, height: 0.1), into: region)
        XCTAssertEqual(mapped.x, 0.7, accuracy: 0.000001)
        XCTAssertEqual(mapped.y, 0.55, accuracy: 0.000001)
        XCTAssertEqual(mapped.width, 0.12, accuracy: 0.000001)
        XCTAssertEqual(mapped.height, 0.06, accuracy: 0.000001)
    }
    func testMergeRemovesDuplicateClassesButKeepsNeighborAndWholeFrameOnlyHit() {
        let box = NormalizedBox(x: 0.5, y: 0.6, width: 0.1, height: 0.08)
        let neighbor = NormalizedBox(x: 0.62, y: 0.6, width: 0.1, height: 0.08)
        let other = NormalizedBox(x: 0.1, y: 0.2, width: 0.2, height: 0.2)
        let merged = CameraDetailDetectorStage.merge([
            ("car", 0.8, box), ("truck", 0.5, box), ("car", 0.7, neighbor), ("car", 0.6, other)
        ])
        XCTAssertEqual(merged.count, 3)
        XCTAssertEqual(merged[0].label, "car")
        XCTAssertEqual(merged[0].confidence, 0.8)
        XCTAssertTrue(merged.contains { $0.box == other })
    }

    /// Opt-in local holdout: no image/model is downloaded, committed or returned.
    /// Input is a camera viewport, not a desktop screenshot. ROI is a known
    /// missed vehicle supplied by the local QA run (top-left normalized).
    func testLocalMissedVehicleHoldout() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let imagePath = env["PLATEWATCH_DETAIL_IMAGE"], let modelPath = env["PLATEWATCH_DETAIL_MODEL"] else {
            throw XCTSkip("Set local camera viewport and installed detector paths to run holdout")
        }
        let image = try XCTUnwrap(CIImage(contentsOf: URL(fileURLWithPath: imagePath)))
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, Int(image.extent.width), Int(image.extent.height), kCVPixelFormatType_32BGRA,
                                          [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixelBuffer = try XCTUnwrap(buffer)
        CIContext().render(image, to: pixelBuffer)
        let model = try MLModel(contentsOf: URL(fileURLWithPath: modelPath))
        let context = AnalysisContext(models: ["vehicle-detection": model], thorough: true, readPlates: false, suppressCameraCaptions: true)
        let input = FramePacketLike(pixelBuffer: pixelBuffer)
        let whole = try await CoreMLDetectorStage(task: "vehicle-detection").process(input, context: context)
        let started = Date()
        let detail = try await CameraDetailDetectorStage().process(input, context: context)
        let target = NormalizedBox(x: 0.80, y: 0.72, width: 0, height: 0)
        func covers(_ box: NormalizedBox) -> Bool {
            box.x < target.x && box.x + box.width > target.x && box.y < target.y && box.y + box.height > target.y
        }
        print("Local detail holdout: whole=\(whole.observations.count), detail=\(detail.observations.count), seconds=\(Date().timeIntervalSince(started))")
        XCTAssertTrue(detail.observations.contains { covers($0.box) }, "White SUV should have a correctly projected vehicle box")
        XCTAssertGreaterThan(detail.observations.count, whole.observations.count)
        XCTAssertTrue(detail.observations.allSatisfy { $0.confidence >= 0.25 })
        // Local/handheld inputs retain the ordinary single-pass detector.
        var localContext = context; localContext.suppressCameraCaptions = false
        let local = try await CameraDetailDetectorStage().process(input, context: localContext)
        XCTAssertEqual(local.observations.count, whole.observations.count)
    }
}
