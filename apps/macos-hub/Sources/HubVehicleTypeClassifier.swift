import CoreImage
import CoreML
import Foundation
import PlateKit
import VehicleML

/// Compatibility adapter for the released ViT tensor model. Image-input models
/// still use the shared Vision stage. This runs locally and returns display types only.
enum HubVehicleTypeClassifier {
    private static let renderer = CIContext(options: [.cacheIntermediates: false])

    static func classify(_ input: FramePacketLike, box: NormalizedBox, context: AnalysisContext) async -> String? {
        guard let model = context.models["vehicle-type-classification"] else { return nil }
        if model.modelDescription.inputDescriptionsByName.values.contains(where: { $0.type == .image }) {
            return await VehicleTypeClassifierStage().classify(input, box: box, context: context)
        }
        guard let feature = model.modelDescription.inputDescriptionsByName["pixel_values"],
              feature.multiArrayConstraint?.shape.map(\.intValue) == [1, 3, 224, 224],
              let tensor = try? tensor(input, box: box) else { return nil }
        return try? predict(model, tensor: tensor)
    }

    private static func predict(_ model: MLModel, tensor: MLMultiArray) throws -> String? {
        bodyType(logits: try logits(model, tensor: tensor))
    }

    enum OutputError: Error { case missingProbabilityDictionary }

    static func logits(_ model: MLModel, tensor: MLMultiArray) throws -> [String: Double] {
        let input = try MLDictionaryFeatureProvider(dictionary: ["pixel_values": MLFeatureValue(multiArray: tensor)])
        let output = try model.prediction(from: input)
        guard let name = model.modelDescription.predictedProbabilitiesName,
              let values = output.featureValue(for: name)?.dictionaryValue else { throw OutputError.missingProbabilityDictionary }
        return Dictionary(uniqueKeysWithValues: values.compactMap { key, value -> (String, Double)? in
            guard let label = key.base as? String else { return nil }
            return (label, value.doubleValue)
        })
    }

    /// The published converter returns logits to ClassifierConfig (not softmax).
    /// Normalize them before applying the shared classifier's 0.45 threshold.
    static func bodyType(logits: [String: Double]) -> String? {
        guard !logits.isEmpty, logits.values.allSatisfy(\.isFinite), let peak = logits.values.max() else { return nil }
        let denominator = logits.values.reduce(0) { $0 + exp($1 - peak) }
        return logits.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .first(where: { exp($0.value - peak) / denominator >= 0.45 && legacyBodyType(for: $0.key) != nil })
            .flatMap { legacyBodyType(for: $0.key) }
    }

    /// Coarse body mapping for the released model's ten classes. These are
    /// appearance labels only: fire engines and taxis never create fleet evidence.
    static func legacyBodyType(for label: String) -> String? {
        switch label.lowercased() {
        case "jeep": return "suv"
        case "racing car", "taxi": return "car"
        case "fire engine": return "truck"
        default: return VehicleTypeClassifierStage.bodyType(for: label)
        }
    }

    /// ViTImageProcessor: resize RGB to 224×224, rescale 1/255,
    /// mean/std 0.5 per channel; NCHW. Verified upstream processor configuration.
    static func tensor(_ input: FramePacketLike, box: NormalizedBox) throws -> MLMultiArray? {
        let source = CIImage(cvPixelBuffer: input.pixelBuffer), extent = CIImage(cvPixelBuffer: input.pixelBuffer).extent
        let crop = CGRect(x: box.x * extent.width, y: (1 - box.y - box.height) * extent.height,
                          width: box.width * extent.width, height: box.height * extent.height).integral.intersection(extent)
        guard crop.width >= 2, crop.height >= 2, let image = renderer.createCGImage(source, from: crop) else { return nil }
        let side = 224
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let canvas = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            canvas.interpolationQuality = .medium
            canvas.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard rendered else { return nil }
        let tensor = try MLMultiArray(shape: [1, 3, 224, 224], dataType: .float32)
        let output = tensor.dataPointer.bindMemory(to: Float.self, capacity: tensor.count)
        let strides = tensor.strides.map(\.intValue)
        for channel in 0..<3 {
            for y in 0..<side {
                for x in 0..<side {
                    output[channel * strides[1] + y * strides[2] + x * strides[3]] = Float(pixels[(y * side + x) * 4 + channel]) / 127.5 - 1
                }
            }
        }
        return tensor
    }
}
