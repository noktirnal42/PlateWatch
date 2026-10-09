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

    /// Decode an image file into a BGRA pixel buffer for Vision/CoreML.
    public static func pixelBuffer(from url: URL) -> CVPixelBuffer? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cg = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }

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
              ) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: cg.width, height: cg.height))
        return pixelBuffer
    }
}
