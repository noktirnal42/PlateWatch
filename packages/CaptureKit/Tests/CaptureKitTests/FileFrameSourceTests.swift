import CoreGraphics
import CoreVideo
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import CaptureKit

final class FileFrameSourceTests: XCTestCase {

    /// Solid-colour JPEG of `width`×`height` stored with an EXIF orientation.
    private func jpeg(width: Int, height: Int, orientation: Int,
                      red: UInt8 = 255, green: UInt8 = 0, blue: UInt8 = 0) throws -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(red: CGFloat(red) / 255, green: CGFloat(green) / 255,
                         blue: CGFloat(blue) / 255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try XCTUnwrap(ctx.makeImage())
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image,
            [kCGImagePropertyOrientation: orientation] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    func testExifRotatedPhotoIsDeliveredUpright() throws {
        // Stored landscape 400×200, tagged "rotate 90° CW" (6) → upright is 200×400.
        let buffer = try XCTUnwrap(FileFrameSource.pixelBuffer(
            from: try jpeg(width: 400, height: 200, orientation: 6)))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 200)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 400)
    }

    func testUnrotatedPhotoKeepsItsShape() throws {
        let buffer = try XCTUnwrap(FileFrameSource.pixelBuffer(
            from: try jpeg(width: 400, height: 200, orientation: 1)))
        XCTAssertEqual(CVPixelBufferGetWidth(buffer), 400)
        XCTAssertEqual(CVPixelBufferGetHeight(buffer), 200)
    }

    func testOversizedPhotoIsBoundedByMaxAnalysisEdge() throws {
        let buffer = try XCTUnwrap(FileFrameSource.pixelBuffer(
            from: try jpeg(width: 6000, height: 3000, orientation: 1)))
        XCTAssertEqual(max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)),
                       FileFrameSource.maxAnalysisEdge)
    }

    func testChannelOrderIsBGRA() throws {
        let buffer = try XCTUnwrap(FileFrameSource.pixelBuffer(
            from: try jpeg(width: 64, height: 64, orientation: 1, red: 255, green: 0, blue: 0)))
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let p = CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to: UInt8.self)
        let offset = 32 * CVPixelBufferGetBytesPerRow(buffer) + 32 * 4
        // BGRA: a red image must have a high R (index 2) and low B (index 0).
        XCTAssertGreaterThan(p[offset + 2], 200)
        XCTAssertLessThan(p[offset + 0], 60)
    }
}
