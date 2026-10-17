import CoreImage
import CoreVideo
import Foundation
import PlateKit

/// Adds bounded, overlapping detail views to the ordinary whole-frame vehicle
/// detector. Small vehicles in wide fixed-camera views otherwise lose most of
/// their pixels when the whole image is fitted to the model's 640px input.
/// This supplies geometry only: fleet classification and redaction stay downstream.
public struct CameraDetailDetectorStage: AnalysisStage {
    public let name = "camera-detail-vehicle-detection"
    private static let renderer = CIContext(options: [.cacheIntermediates: false])
    static let regions: [NormalizedBox] = [
        .init(x: 0, y: 0, width: 0.6, height: 0.6),
        .init(x: 0.4, y: 0, width: 0.6, height: 0.6),
        .init(x: 0, y: 0.4, width: 0.6, height: 0.6),
        .init(x: 0.4, y: 0.4, width: 0.6, height: 0.6)
    ]
    public init() {}

    public func process(_ input: FramePacketLike, context: AnalysisContext) async throws -> CoreMLDetectorStage.DetectedObjects {
        let detector = CoreMLDetectorStage(task: "vehicle-detection")
        let whole = try await detector.process(input, context: context)
        guard context.thorough, context.suppressCameraCaptions,
              max(CVPixelBufferGetWidth(input.pixelBuffer), CVPixelBufferGetHeight(input.pixelBuffer)) >= 960 else { return whole }
        let image = CIImage(cvPixelBuffer: input.pixelBuffer)
        var candidates = whole.observations
        for region in Self.regions {
            try Task.checkCancellation()
            guard let tile = Self.crop(image, region: region) else { continue }
            // Keep the same model and threshold, and preserve the full-frame
            // answer if any extra crop fails. No extra OCR or plate recognition.
            guard let detail = try? await detector.process(.init(pixelBuffer: tile), context: context) else { continue }
            candidates += detail.observations.compactMap { hit in
                // A detail tile may cut through a larger vehicle. Edge-truncated
                // boxes are left to the whole-frame detector or an overlapping tile.
                let b = hit.box
                guard !(region.x > 0 && b.x <= 0.015),
                      !(region.y > 0 && b.y <= 0.015),
                      !(region.x + region.width < 1 && b.x + b.width >= 0.985),
                      !(region.y + region.height < 1 && b.y + b.height >= 0.985) else { return nil }
                return (hit.label, hit.confidence, Self.project(b, into: region))
            }
        }
        return .init(observations: Self.merge(candidates))
    }

    static func project(_ box: NormalizedBox, into region: NormalizedBox) -> NormalizedBox {
        .init(x: region.x + box.x * region.width, y: region.y + box.y * region.height,
              width: box.width * region.width, height: box.height * region.height)
    }

    /// Class-agnostic suppression prevents a car/truck ambiguity from producing
    /// two overlays on the same vehicle; separated neighbors remain independent.
    static func merge(_ candidates: [(label: String, confidence: Double, box: NormalizedBox)]) -> [(label: String, confidence: Double, box: NormalizedBox)] {
        var kept: [(label: String, confidence: Double, box: NormalizedBox)] = []
        for hit in candidates.sorted(by: { $0.confidence > $1.confidence }) {
            guard hit.confidence.isFinite, hit.box.width > 0, hit.box.height > 0 else { continue }
            if !kept.contains(where: { overlap($0.box, hit.box) > 0.45 }) { kept.append(hit) }
        }
        return kept
    }

    private static func overlap(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let w = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
        let h = max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        let intersection = w * h
        return intersection / max(0.000001, a.width * a.height + b.width * b.height - intersection)
    }

    private static func crop(_ image: CIImage, region: NormalizedBox) -> CVPixelBuffer? {
        let extent = image.extent
        let rect = CGRect(x: extent.minX + region.x * extent.width,
                          y: extent.minY + (1 - region.y - region.height) * extent.height,
                          width: region.width * extent.width, height: region.height * extent.height).integral.intersection(extent)
        guard rect.width >= 1, rect.height >= 1 else { return nil }
        var buffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(rect.width), Int(rect.height), kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        let tile = image.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
        renderer.render(tile, to: buffer)
        return buffer
    }
}
