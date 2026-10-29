import CoreVideo
import XCTest
@testable import VehicleML

final class VehicleColorClassifierTests: XCTestCase {
    func testPureColorsAndNeutrals() {
        XCTAssertEqual(VehicleColorClassifier.classify(red: 0.95, green: 0.95, blue: 0.95)?.color, "white")
        XCTAssertEqual(VehicleColorClassifier.classify(red: 0.03, green: 0.03, blue: 0.03)?.color, "black")
        XCTAssertEqual(VehicleColorClassifier.classify(red: 0.08, green: 0.08, blue: 0.08)?.color, "charcoal")
        XCTAssertEqual(VehicleColorClassifier.classify(red: 0.12, green: 0.42, blue: 0.92)?.color, "blue")
    }

    func testBufferSamplesNormalizedVehicleBox() throws {
        var buffer: CVPixelBuffer?
        XCTAssertEqual(CVPixelBufferCreate(kCFAllocatorDefault, 16, 16, kCVPixelFormatType_32BGRA,
                                           [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer), kCVReturnSuccess)
        let pixel = try XCTUnwrap(buffer)
        CVPixelBufferLockBaseAddress(pixel, [])
        defer { CVPixelBufferUnlockBaseAddress(pixel, []) }
        let bytes = CVPixelBufferGetBaseAddress(pixel)!.assumingMemoryBound(to: UInt8.self)
        for i in stride(from: 0, to: 16 * CVPixelBufferGetBytesPerRow(pixel), by: 4) {
            bytes[i] = 20; bytes[i + 1] = 30; bytes[i + 2] = 235; bytes[i + 3] = 255
        }
        let cue = VehicleColorClassifier.classify(pixel, box: (x: 0, y: 0, width: 1, height: 1))
        XCTAssertEqual(cue?.color, "red")
    }
}
