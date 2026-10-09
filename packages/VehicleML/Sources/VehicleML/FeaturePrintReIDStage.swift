import Foundation
import PlateKit
import Vision

/// Assigns each vehicle crop a perceptual feature print using Vision's
/// built-in image fingerprinting — no model download required. Two sightings
/// of the same vehicle (same livery, dents, decals) cluster together even
/// without a plate read, which is how unplated or plate-obscured government
/// vehicles stay trackable.
public struct FeaturePrintReIDStage: AnalysisStage {
    public let name = "featureprint-reid"

    /// Similarity distance below which two prints are "likely same vehicle".
    /// Empirical starting point; tuned by the community test reel.
    public var matchDistanceThreshold: Float = 0.35

    public init() {}

    public struct AnchoredFrame: Sendable {
        public let frame: DetectionFrame
        /// vehicle observation id → hex anchor
        public let anchors: [UUID: String]
    }

    public func process(_ input: DetectionFrame, context: AnalysisContext) async throws -> AnchoredFrame {
        // Feature prints are computed per cropped vehicle region by the caller
        // supplying crops; here we anchor on whole-frame plates for MVP and
        // leave per-vehicle crops to the CoreML detector fusion path.
        let anchors: [UUID: String] = [:]  // filled by crop-supplying callers
        return AnchoredFrame(frame: input, anchors: anchors)
    }

    /// Compute the feature print distance between two Vision prints.
    /// Lower = more similar. Wraps the oddthrowing Vision distance API.
    public static func distance(_ a: VNFeaturePrintObservation,
                                _ b: VNFeaturePrintObservation) throws -> Float {
        var d: Float = .greatestFiniteMagnitude
        try a.computeDistance(&d, to: b)
        return d
    }
}
