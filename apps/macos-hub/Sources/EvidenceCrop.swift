import AppKit
import CoreImage
import CoreVideo
import CryptoKit
import Foundation
import PlateKit

/// Evidence image for a recorded fleet hit: the vehicle cropped out of the
/// analysed frame, encoded as a JPEG within the `cropJPEGBase64` wire cap
/// (≤ 40 KB), with `cropHashSHA256` as the integrity anchor (DATA-MODEL).
///
/// Local Review preserves the target crop as captured: no overlap-based
/// suppression and no blacking out plate/text regions. Reviewers need that
/// context to judge the detector. Incidental background content stays local;
/// this is not permission to index private plates or upload image bytes.
/// See LEGAL-ETHICS Rule 1, local Review exception.
enum EvidenceCrop {
    /// Wire cap documented on `SightingSubmissionDTO.cropJPEGBase64`.
    static let maxBytes = 40_000
    /// Long-side ceiling for the stored crop: large enough to read unit
    /// lettering at full size, small enough to stay far under the cap.
    static let maxLongSide: CGFloat = 640
    /// Context margin around the detector box — roof/door lettering and
    /// bumpers regularly sit outside the detected box.
    static let margin: CGFloat = 0.12

    struct Output: Sendable, Equatable {
        let jpegData: Data
        let sha256Hex: String
        var base64: String { jpegData.base64EncodedString() }
    }

    /// The analysed frame as an immutable bitmap, handed from a capture
    /// thread to the recorder. The pixel buffer is rendered to a CGImage
    /// lazily — once, and only if a recorded hit actually needs it — so
    /// frames without hits never pay for a conversion.
    final class SourceFrame: @unchecked Sendable {
        private let pixelBuffer: CVPixelBuffer?
        private var cached: CGImage?
        private let lock = NSLock()

        init(pixelBuffer: CVPixelBuffer?) {
            self.pixelBuffer = pixelBuffer
        }

        var image: CGImage? {
            lock.lock()
            defer { lock.unlock() }
            if let cached { return cached }
            guard let pixelBuffer else { return nil }
            let ci = CIImage(cvPixelBuffer: pixelBuffer)
            let rendered = Self.context.createCGImage(ci, from: ci.extent)
            cached = rendered
            return rendered
        }

        private static let context = CIContext()
    }

    /// Builds an intact local crop. Missing frames, invalid geometry or
    /// encoding failure can omit it; neighboring detections cannot.
    static func make(source: SourceFrame, vehicle: VehicleObservation,
                     others: [VehicleObservation]) -> Output? {
        guard let frame = source.image else { return nil }
        let size = CGSize(width: frame.width, height: frame.height)
        guard let cropBox = expanded(vehicle.boundingBox, in: size) else { return nil }

        let cropRect = CGRect(x: cropBox.x * size.width, y: cropBox.y * size.height,
                              width: cropBox.width * size.width, height: cropBox.height * size.height)
            .integral
        guard cropRect.width >= 8, cropRect.height >= 8,
              let cropped = frame.cropping(to: cropRect) else { return nil }

        return encoded(cropped)
    }

    // MARK: - Geometry

    /// Grows the box by `margin` of its own extent per side (context for
    /// roof/door lettering), clamped to the image.
    private static func expanded(_ box: NormalizedBox, in size: CGSize) -> NormalizedBox? {
        guard [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0 else { return nil }
        let dx = box.width * margin, dy = box.height * margin
        let rect = box.cgRect.insetBy(dx: -dx, dy: -dy)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !rect.isNull, !rect.isEmpty else { return nil }
        return NormalizedBox(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
    }

    // MARK: - Encoding

    private static func encoded(_ image: CGImage) -> Output? {
        var current = fitted(image)
        var scale: CGFloat = 1.0
        while scale >= 0.35 {
            var quality = 0.8
            while quality >= 0.3 {
                if let data = jpeg(current, quality: quality), data.count <= maxBytes {
                    return Output(jpegData: data, sha256Hex: sha256Hex(data))
                }
                quality -= 0.15
            }
            scale -= 0.2
            guard let smaller = resized(current, by: scale) else { break }
            current = smaller
        }
        return nil
    }

    private static func fitted(_ image: CGImage) -> CGImage {
        let longSide = CGFloat(max(image.width, image.height))
        guard longSide > maxLongSide else { return image }
        return resized(image, by: maxLongSide / longSide) ?? image
    }

    private static func resized(_ image: CGImage, by factor: CGFloat) -> CGImage? {
        let width = max(1, Int((CGFloat(image.width) * factor).rounded()))
        let height = max(1, Int((CGFloat(image.height) * factor).rounded()))
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    private static func jpeg(_ image: CGImage, quality: Double) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
