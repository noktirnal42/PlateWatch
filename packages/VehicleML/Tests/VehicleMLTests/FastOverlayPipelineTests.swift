import CoreImage
import CoreVideo
import CoreText
import PlateKit
import XCTest
@testable import VehicleML

final class FastOverlayPipelineTests: XCTestCase {
    private func frame(text: String? = nil) throws -> FramePacketLike {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 640, 480, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixels = try XCTUnwrap(buffer)
        CIContext().render(CIImage(color: CIColor(red: 0, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 640, height: 480)), to: pixels)
        if let text {
            CVPixelBufferLockBaseAddress(pixels, [])
            defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
            let canvas = try XCTUnwrap(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 640, height: 480,
                bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels), space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            let string = NSAttributedString(string: text, attributes: [
                NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 64, nil),
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: 1, alpha: 1)])
            canvas.textPosition = CGPoint(x: 30, y: 200)
            CTLineDraw(CTLineCreateWithAttributedString(string), canvas)
        }
        return FramePacketLike(pixelBuffer: pixels)
    }

    func testOverlayWithoutDetectorReturnsEmptyFrameInsteadOfFallback() async throws {
        let timestamp = Date(timeIntervalSince1970: 123)
        let input = try frame(text: "POLICE UNIT 42")
        let baseline = try await PlateAnalysisPipeline().analyze(input, context: .init(thorough: true))
        XCTAssertFalse(baseline.vehicles.flatMap(\.sceneText).isEmpty, "The fixture must exercise actual baseline OCR")
        let result = try await PlateAnalysisPipeline().analyze(input,
            context: .init(timestamp: timestamp, thorough: true, boxesOnly: true))
        XCTAssertEqual(result.timestamp, timestamp)
        XCTAssertEqual(result.imageSize, CGSize(width: 640, height: 480))
        XCTAssertTrue(result.vehicles.isEmpty)
    }

    func testDetectorOverlayHasGeometryButNoOCROrPlateEvidence() throws {
        let box = NormalizedBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
        let result = PlateAnalysisPipeline.detectorOverlay([("car", 0.9, box)], frame: try frame(), context: .init())
        let vehicle = try XCTUnwrap(result.vehicles.first)
        XCTAssertEqual(vehicle.boundingBox, box)
        XCTAssertEqual(vehicle.attributes?.bodyType, "car")
        XCTAssertFalse(vehicle.vehicleClass.isFleet)
        XCTAssertTrue(vehicle.plates.isEmpty)
        XCTAssertTrue(vehicle.sceneText.isEmpty)
        XCTAssertTrue(PlateAnalysisPipeline.typeClassificationIndices(result.vehicles, imageSize: result.imageSize, thorough: true).isEmpty)
    }

    func testSpecializedDetectorLabelCannotEstablishFleetOnFastPath() throws {
        let result = PlateAnalysisPipeline.detectorOverlay([("police_car", 0.99, .init(x: 0, y: 0, width: 1, height: 1))],
                                                          frame: try frame(), context: .init())
        XCTAssertFalse(try XCTUnwrap(result.vehicles.first).vehicleClass.isFleet)
    }

    func testOffscreenCropDoesNotConsumeClassificationBudget() {
        let offscreen = VehicleObservation(boundingBox: .init(x: 1.1, y: 0.2, width: 0.5, height: 0.5))
        XCTAssertEqual(PlateAnalysisPipeline.typeClassificationIndices([offscreen, vehicle()],
            imageSize: .init(width: 1000, height: 1000), thorough: false), [1])
    }

    private func vehicle(body: String? = nil, width: Double = 0.1, height: Double = 0.1) -> VehicleObservation {
        VehicleObservation(boundingBox: .init(x: 0.2, y: 0.2, width: width, height: height),
                           attributes: body.map { VehicleAttributes(bodyType: $0) })
    }

    func testKnownTypesDoNotStarveLaterEligibleCrops() {
        let vehicles = Array(repeating: vehicle(body: "car"), count: 10) + [vehicle(), vehicle()]
        XCTAssertEqual(PlateAnalysisPipeline.typeClassificationIndices(vehicles, imageSize: .init(width: 1000, height: 1000), thorough: false), [10, 11])
    }

    func testLiveAndStillClassificationBudgets() {
        let vehicles = Array(repeating: vehicle(), count: 12)
        let size = CGSize(width: 1000, height: 1000)
        XCTAssertEqual(PlateAnalysisPipeline.typeClassificationIndices(vehicles, imageSize: size, thorough: false), [0, 1, 2, 3])
        XCTAssertEqual(PlateAnalysisPipeline.typeClassificationIndices(vehicles, imageSize: size, thorough: true), Array(0..<8))
    }

    func testTinyAndThinCropsDoNotConsumeBudget() {
        let vehicles = [vehicle(width: 0.047), vehicle(height: 0.047), vehicle(width: 0.048, height: 0.048)]
        XCTAssertEqual(PlateAnalysisPipeline.typeClassificationIndices(vehicles, imageSize: .init(width: 1000, height: 1000), thorough: false), [2])
    }
}
