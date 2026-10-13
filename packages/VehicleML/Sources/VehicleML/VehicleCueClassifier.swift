import Foundation
import PlateKit
import Vision

/// Image-level "what kind of vehicle is this" cue from Apple's built-in
/// Vision classifier (`VNClassifyImageRequest`) — no model download, runs on
/// the Neural Engine. It knows `police_car`, `firetruck`, `ambulance` and
/// `bus`, which is exactly the vocabulary the fleet gate needs while the
/// project's own CoreML classifiers are not shipped yet.
///
/// A cue is *evidence*, not a verdict: on its own it contributes at most
/// 0.45 × confidence to the fleet score (< the 0.55 persist threshold), so a
/// police-shaped car with no corroborating text is never published.
public struct VehicleCue: Sendable, Equatable {
    public var vehicleClass: VehicleClass
    public var confidence: Double
    public var label: String
}

public enum VehicleCueClassifier {

    /// Vision label → (class, weight). Buses are weighted down: a charter or
    /// tour coach is not a public vehicle, so a bus needs transit text too.
    static let labels: [String: (VehicleClass, Double)] = [
        "police_car": (.patrol, 1.0),
        "firetruck": (.fireEngine, 1.0),
        "ambulance": (.ambulance, 1.0),
        "bus": (.transit, 0.6),
    ]

    public static let minimumConfidence = 0.30

    public static func classify(_ pixelBuffer: CVPixelBuffer) -> VehicleCue? {
        let request = VNClassifyImageRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        guard (try? handler.perform([request])) != nil else { return nil }
        var best: VehicleCue?
        for observation in request.results ?? [] {
            guard let (cls, weight) = labels[observation.identifier] else { continue }
            let score = Double(observation.confidence) * weight
            if score >= minimumConfidence, score > (best?.confidence ?? 0) {
                best = VehicleCue(vehicleClass: cls, confidence: score, label: observation.identifier)
            }
        }
        return best
    }
}
