import CoreImage
import CoreML
import CoreVideo
import Foundation
import PlateKit
import Vision

/// Applies the optional on-device vehicle-type classifier to one detected crop.
/// This only enriches the display attribute; it never promotes a vehicle to a
/// fleet class and it never changes the redaction gate.
public struct VehicleTypeClassifierStage: Sendable {
    public let name = "vehicle-type-classification"
    public var confidenceThreshold: Float = 0.45

    public init() {}

    public func classify(_ input: FramePacketLike, box: NormalizedBox,
                         context: AnalysisContext) async -> String? {
        guard let model = context.models[name], let crop = Self.crop(input.pixelBuffer, box: box) else { return nil }
        do {
            let visionModel = try VNCoreMLModel(for: model)
            return try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)
                let request = VNCoreMLRequest(model: visionModel) { request, error in
                    if let error { once.resume(throwing: error); return }
                    let result = (request.results as? [VNClassificationObservation] ?? [])
                        .first(where: { $0.confidence >= self.confidenceThreshold && Self.bodyType(for: $0.identifier) != nil })
                    once.resume(returning: result.flatMap { Self.bodyType(for: $0.identifier) })
                }
                request.imageCropAndScaleOption = .centerCrop
                do { try VNImageRequestHandler(cvPixelBuffer: crop, options: [:]).perform([request]) }
                catch { once.resume(throwing: error) }
            }
        } catch {
            return nil
        }
    }

    /// Keeps only labels that are useful to an operator and safe to expose as
    /// a coarse body type. Other classifier labels (bicycle, boat, person,
    /// etc.) are intentionally ignored.
    public static func bodyType(for label: String) -> String? {
        let value = label
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .lowercased()
        if value.contains("motorcycle") || value.contains("motorbike") { return "motorcycle" }
        if value.contains("suv") || value.contains("sport utility") { return "suv" }
        if value.contains("pickup") || value.contains("pick up") { return "pickup truck" }
        if value.contains("minivan") || value.contains("mini van") || value == "van" { return "van" }
        if value.contains("bus") || value.contains("coach") { return "bus" }
        if value.contains("truck") || value.contains("lorry") { return "truck" }
        if value.contains("sedan") || value.contains("coupe") || value.contains("hatchback") || value == "car" || value == "automobile" {
            return "car"
        }
        return nil
    }

    private static let renderer = CIContext(options: [.cacheIntermediates: false])

    private static func crop(_ pixelBuffer: CVPixelBuffer, box: NormalizedBox) -> CVPixelBuffer? {
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        let extent = image.extent
        let rect = CGRect(x: extent.minX + box.x * extent.width,
                          y: extent.minY + (1 - box.y - box.height) * extent.height,
                          width: box.width * extent.width,
                          height: box.height * extent.height).integral.intersection(extent)
        guard rect.width >= 2, rect.height >= 2 else { return nil }
        var output: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, Int(rect.width), Int(rect.height),
                                  kCVPixelFormatType_32BGRA,
                                  [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                  &output) == kCVReturnSuccess, let output else { return nil }
        let cropped = image.cropped(to: rect).transformed(by: .init(translationX: -rect.minX, y: -rect.minY))
        renderer.render(cropped, to: output)
        return output
    }
}
