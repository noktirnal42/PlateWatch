import CoreGraphics
import CoreText
import CoreVideo
import PlateKit
import XCTest
@testable import VehicleML

/// Renders a mock cruiser door panel and runs the real Vision baseline over it.
final class DoorTextPipelineTests: XCTestCase {

    private func panel(lines: [String], plate: String? = nil) throws -> CVPixelBuffer {
        let width = 1600, height = 900
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        let pb = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        let ctx = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(CGColor(gray: 0.08, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func draw(_ text: String, at point: CGPoint, size: CGFloat, color: CGColor) {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, size, nil)
            let attrs: [CFString: Any] = [kCTFontAttributeName: font, kCTForegroundColorAttributeName: color]
            let line = CTLineCreateWithAttributedString(
                CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary))
            ctx.textPosition = point
            CTLineDraw(line, ctx)
        }
        var y = CGFloat(height) - 220
        for text in lines {
            draw(text, at: CGPoint(x: 120, y: y), size: 130, color: CGColor(gray: 1, alpha: 1))
            y -= 190
        }
        if let plate {
            ctx.setFillColor(CGColor(gray: 0.95, alpha: 1))
            ctx.fill(CGRect(x: 1000, y: 120, width: 520, height: 260))
            draw(plate, at: CGPoint(x: 1030, y: 215), size: 95, color: CGColor(gray: 0.05, alpha: 1))
        }
        return pb
    }

    func testDoorTextWithoutPlateStillYieldsAFleetVehicle() async throws {
        let frame = try await PlateAnalysisPipeline().analyze(
            FramePacketLike(pixelBuffer: try panel(lines: ["CITY OF AUSTIN", "POLICE", "UNIT 4421"])),
            context: AnalysisContext(models: [:]))
        let vehicle = try XCTUnwrap(frame.vehicles.first, "no vehicle from door text")
        XCTAssertEqual(vehicle.vehicleClass, .patrol)
        XCTAssertTrue(SceneTextHeuristics.parse(vehicle.sceneText).hasFleetKeyword)

        // And the gate accepts it without any CoreML classifier.
        let markings = SceneTextHeuristics.parse(vehicle.sceneText)
        let gate = RedactionGate(config: .standard)
        let c = gate.fleetConfidence(vehicleClassifierFleet: 0, markings: markings,
                                     knownUnitMatch: false, exemptPlateDesign: false)
        XCTAssertEqual(gate.verdict(fleetConfidence: c), .persistAndSync, "markings: \(markings)")
    }

    func testCivilianTextProducesNoVehicle() async throws {
        let frame = try await PlateAnalysisPipeline().analyze(
            FramePacketLike(pixelBuffer: try panel(lines: ["SYSTEMS", "ITEMS FOR SALE"])),
            context: AnalysisContext(models: [:]))
        XCTAssertTrue(frame.vehicles.allSatisfy { !$0.vehicleClass.isFleet })
    }

    func testLettersOnlyBrandWordIsNotAPlate() async throws {
        let frame = try await PlateAnalysisPipeline().analyze(
            FramePacketLike(pixelBuffer: try panel(lines: [], plate: "FALCK")),
            context: AnalysisContext(models: [:]))
        XCTAssertTrue(frame.vehicles.flatMap(\.plates).isEmpty, "a brand word must not read as a plate")
    }

    func testRenderedPlateIsRead() async throws {
        let frame = try await PlateAnalysisPipeline().analyze(
            FramePacketLike(pixelBuffer: try panel(lines: [], plate: "7ABC123")),
            context: AnalysisContext(models: [:]))
        let reads = frame.vehicles.flatMap(\.plates).compactMap(\.best).map { Plate.normalize($0.text) }
        XCTAssertTrue(reads.contains("7ABC123"), "plate reads: \(reads)")
    }
}

final class EdgePlateRegressionTests: XCTestCase {
    /// A plate flush against the image edge produced a padded ROI outside
    /// [0,1], Vision threw, and the whole frame failed to analyze.
    func testPlateTouchingImageEdgeDoesNotFailTheFrame() async throws {
        let width = 1200, height = 800
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                            [kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &buffer)
        let pb = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pb, [])
        let ctx = try XCTUnwrap(CGContext(
            data: CVPixelBufferGetBaseAddress(pb), width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pb),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        ctx.setFillColor(CGColor(gray: 0.1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 420, height: 160))
        let font = CTFontCreateWithName("Helvetica-Bold" as CFString, 100, nil)
        let line = CTLineCreateWithAttributedString(CFAttributedStringCreate(
            nil, "7ABC123" as CFString,
            [kCTFontAttributeName: font, kCTForegroundColorAttributeName: CGColor(gray: 0.05, alpha: 1)] as CFDictionary))
        ctx.textPosition = CGPoint(x: 6, y: 30); CTLineDraw(line, ctx)
        CVPixelBufferUnlockBaseAddress(pb, [])

        let frame = try await PlateAnalysisPipeline().analyze(
            FramePacketLike(pixelBuffer: pb), context: AnalysisContext(models: [:]))
        XCTAssertEqual(frame.imageSize.width, 1200) // analysis completed instead of throwing
    }
}
