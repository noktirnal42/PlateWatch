import AVFoundation
import CoreGraphics
import Foundation

/// Non-camera frame sources: photo library import, directories of stills
/// (Mac hub snapshot ingest), or pre-recorded test reels. All normalize to
/// `FramePacket` so the pipeline never knows the difference.
public struct FileFrameSource: Sendable {

    public enum SourceError: Error {
        case cannotDecodeImage(String)
    }

    public init() {}

    /// Load frames from image URLs in stable name order.
    public func frames(from urls: [URL]) throws -> [FramePacket] {
        try urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            .enumerated()
            .map { index, url in
                guard let buffer = Self.pixelBuffer(from: url) else {
                    throw SourceError.cannotDecodeImage(url.path)
                }
                return FramePacket(pixelBuffer: buffer, timestamp: Date(),
                                   sequenceNumber: UInt64(index))
            }
    }

    /// Longest edge, in pixels, handed to the analyzers. Plates stay legible
    /// at this size while a 48 MP photo no longer costs ~200 MB of BGRA.
    public static let maxAnalysisEdge = 3072

    /// Decode an image file into an upright BGRA pixel buffer for Vision/CoreML.
    public static func pixelBuffer(from url: URL) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return pixelBuffer(from: source)
    }

    /// Decode raw image data into an upright BGRA pixel buffer.
    public static func pixelBuffer(from data: Data) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return pixelBuffer(from: source)
    }

    /// Phone photos are stored in sensor orientation with an EXIF rotation
    /// tag. `CGImageSourceCreateImageAtIndex` ignores it, which fed every
    /// portrait photo to Vision sideways. The thumbnail API applies the
    /// transform and bounds the size in one pass.
    private static func pixelBuffer(from source: CGImageSource) -> CVPixelBuffer? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxAnalysisEdge,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
        else { return nil }

        var buffer: CVPixelBuffer?
        let result = CVPixelBufferCreate(
            kCFAllocatorDefault, cg.width, cg.height, kCVPixelFormatType_32BGRA,
            [kCVPixelBufferCGImageCompatibilityKey: true,
             kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary,
            &buffer)
        guard result == kCVReturnSuccess, let pixelBuffer = buffer else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
              let ctx = CGContext(
                data: baseAddress, width: cg.width, height: cg.height,
                bitsPerComponent: 8,
                bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                    | CGBitmapInfo.byteOrder32Little.rawValue
              ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pixelBuffer
    }
}
