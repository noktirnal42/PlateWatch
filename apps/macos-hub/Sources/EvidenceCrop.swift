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
/// Redaction policy (LEGAL-ETHICS Rule 1 — private plates never leave a
/// capture): another detected vehicle intruding into the crop cancels it
/// entirely; other vehicles' detected plate/text boxes are blocked out.
/// The target vehicle's own plates and unit lettering are the evidence and
/// are kept. The analysis pipeline has no face/person models
/// (docs/FEED-SOURCES.md §6b), so no facial regions are ever classified —
/// and none need redacting.
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

    /// Builds the crop, or nil when policy says no image should be stored:
    /// no source frame, another vehicle genuinely intruding into the crop,
    /// or an encoding that will not fit under the wire cap.
    static func make(source: SourceFrame, vehicle: VehicleObservation,
                     others: [VehicleObservation]) -> Output? {
        guard let frame = source.image else { return nil }
        let size = CGSize(width: frame.width, height: frame.height)
        guard let cropBox = expanded(vehicle.boundingBox, in: size) else { return nil }

        // A vehicle substantially inside the crop area would contribute
        // plate/text we cannot reliably attribute or redact (its own boxes
        // may be undetected) — skip rather than guess.
        for other in others where other.id != vehicle.id {
            let inter = other.boundingBox.cgRect.intersection(cropBox.cgRect)
            guard !inter.isNull else { continue }
            let otherArea = other.boundingBox.cgRect.width * other.boundingBox.cgRect.height
            if otherArea > 0, inter.width * inter.height / otherArea > 0.2 { return nil }
        }

        let cropRect = CGRect(x: cropBox.x * size.width, y: cropBox.y * size.height,
                              width: cropBox.width * size.width, height: cropBox.height * size.height)
            .integral
        guard cropRect.width >= 8, cropRect.height >= 8,
              let cropped = frame.cropping(to: cropRect) else { return nil }

        // Any other vehicle's detected plate or scene text still inside the
        // crop (margin graze) is blocked out before anything is stored.
        var foreign: [CGRect] = []
        for other in others where other.id != vehicle.id {
            for box in other.plates.map(\.boundingBox) + other.sceneText.map(\.boundingBox) {
                let px = CGRect(x: box.x * size.width, y: box.y * size.height,
                                width: box.width * size.width, height: box.height * size.height)
                if px.intersects(cropRect) {
                    foreign.append(px.intersection(cropRect)
                        .offsetBy(dx: -cropRect.minX, dy: -cropRect.minY))
                }
            }
        }
        guard let redacted = redact(foreign, in: cropped) else { return nil }
        return encoded(redacted)
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

    // MARK: - Redaction

    /// Opaque dark blocks over the given pixel-space rects (top-left origin
    /// coordinates). Deliberately a visible FOIA-style redaction, not an
    /// erase: what was covered stays evident.
    private static func redact(_ rects: [CGRect], in image: CGImage) -> CGImage? {
        guard !rects.isEmpty else { return image }
        let width = image.width, height = image.height
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                                      | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(gray: 0.12, alpha: 1))
        for rect in rects {
            // Top-left origin (Vision/NormalizedBox convention) → CG user space.
            let flipped = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY,
                                 width: rect.width, height: rect.height)
            ctx.fill(flipped.insetBy(dx: -2, dy: -2))
        }
        return ctx.makeImage()
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
