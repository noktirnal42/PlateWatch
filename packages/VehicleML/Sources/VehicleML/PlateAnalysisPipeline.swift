import CoreML
import Foundation
import PlateKit
import Vision

/// Generic VNCoreMLRequest-backed object detector stage. Works for both
/// "vehicle-detection" and "plate-detection" tasks — the registry's `task`
/// field decides which role a loaded model plays.
public struct CoreMLDetectorStage: AnalysisStage {
    public let name: String
    public let task: String
    public var confidenceThreshold: Float = 0.25
    /// Labels counted as fleet-relevant for gating purposes when a
    /// vehicle-class labels list is present in the model.
    public var fleetLabels: Set<String> = ["police", "police_car", "fire_truck",
                                           "ambulance", "bus", "truck"]

    public init(task: String, name: String? = nil) {
        self.task = task
        self.name = name ?? "coreml-detect:\(task)"
    }

    public struct DetectedObjects: Sendable {
        public var observations: [(label: String, confidence: Double, box: NormalizedBox)]
    }

    public func process(_ input: FramePacketLike, context: AnalysisContext) async throws -> DetectedObjects {
        guard let model = context.models[task] else {
            throw AnalysisError.modelMissing(task: task)
        }
        let visionModel = try VNCoreMLModel(for: model)
        // Map to sendable values inside the handler (VN types are not Sendable).
        typealias Hit = (label: String, confidence: Double, box: NormalizedBox)
        let threshold = Double(confidenceThreshold)
        let hits: [Hit] = try await withCheckedThrowingContinuation { cont in
            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                var out: [Hit] = []
                for obs in (request.results as? [VNRecognizedObjectObservation]) ?? [] {
                    guard let label = obs.labels.first?.identifier else { continue }
                    let confidence = Double(obs.confidence)
                    guard confidence >= threshold else { continue }
                    out.append(Hit(label, confidence, NormalizedBox(visionRect: obs.boundingBox)))
                }
                cont.resume(returning: out)
            }
            request.imageCropAndScaleOption = .scaleFit
            let handler = VNImageRequestHandler(cvPixelBuffer: input.pixelBuffer, options: [:])
            do { try handler.perform([request]) }
            catch { cont.resume(throwing: AnalysisError.visionRequestFailed(error.localizedDescription)) }
        }
        return DetectedObjects(observations: hits)
    }
}

/// End-to-end analyzer that uses detector stages when available and always
/// keeps the Vision text fallback for plate reading. This is the public
/// entry point apps construct.
public struct PlateAnalysisPipeline: Sendable {
    public struct Configuration: Sendable {
        public var candidateRegions: [String] = []
        public init(candidateRegions: [String] = []) {
            self.candidateRegions = candidateRegions
        }
    }

    private let baseline: VisionBaselineAnalyzer
    public init(configuration: Configuration = .init()) {
        self.baseline = VisionBaselineAnalyzer(candidateRegions: configuration.candidateRegions)
    }

    /// Analyze one frame. Detector results from installed CoreML models are
    /// fused with baseline text reads when available; missing models degrade
    /// gracefully to the Vision-only baseline.
    public func analyze(_ frame: FramePacketLike,
                        context: AnalysisContext) async throws -> DetectionFrame {

        var vehicleObservations: [VehicleObservation] = []
        if context.models["vehicle-detection"] != nil {
            let stage = CoreMLDetectorStage(task: "vehicle-detection")
            if let detected = try? await stage.process(frame, context: context) {
                vehicleObservations = detected.observations.map {
                    let cls = VehicleClass(rawValue: $0.label) ?? ($0.label.hasPrefix("police") ? .patrol : .unknown)
                    return VehicleObservation(boundingBox: $0.box,
                                              vehicleClass: cls,
                                              classConfidence: $0.confidence)
                }
            }
        }

        let baselineFrame = try await baseline.process(frame, context: context)

        if vehicleObservations.isEmpty {
            return baselineFrame // baseline boxes are the answer today
        }

        // Fuse: attach baseline plates/scene text to the detected vehicle box
        // that contains them.
        var fused = vehicleObservations
        for index in fused.indices {
            let box = fused[index].boundingBox
            fused[index].plates = baselineFrame.vehicles
                .flatMap(\.plates)
                .filter { box.contains(centerOf: $0.boundingBox) }
            fused[index].sceneText = baselineFrame.vehicles
                .flatMap(\.sceneText)
                .filter { box.contains(centerOf: $0.boundingBox) }
        }
        var out = baselineFrame
        out.vehicles = fused
        return out
    }
}

private extension NormalizedBox {
    func contains(centerOf other: NormalizedBox) -> Bool {
        let cx = other.x + other.width / 2
        let cy = other.y + other.height / 2
        return (x..<(x + width)).contains(cx) && (y..<(y + height)).contains(cy)
    }
}
