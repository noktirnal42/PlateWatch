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

    /// Generic COCO output includes people, traffic lights and other objects.
    /// A vehicle stage must not relabel those as unknown vehicles.
    static let vehicleLabels = Set(["car", "truck", "bus", "motorcycle"]).union(VehicleClass.allCases.map(\.rawValue))
    static func vehicleClass(for label: String) -> VehicleClass {
        if let value = VehicleClass(rawValue: label) { return value }
        switch label {
        case "police", "police_car": return .patrol
        case "fire_truck": return .fireEngine
        default: return .unknown // Generic bus/truck appearance is not fleet evidence.
        }
    }

    /// Generic body class is useful for overlays but must not promote a car/bus/truck to fleet.
    static func observation(label: String, confidence: Double, box: NormalizedBox) -> VehicleObservation {
        let body = ["car", "truck", "bus", "motorcycle"].contains(label) ? label : nil
        return VehicleObservation(boundingBox: box, vehicleClass: vehicleClass(for: label),
            classConfidence: confidence, attributes: body.map { VehicleAttributes(bodyType: $0) })
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
        let allowed = task == "vehicle-detection" ? Self.vehicleLabels.union(fleetLabels) : nil
        let hits: [Hit] = try await withCheckedThrowingContinuation { continuation in
            let cont = ResumeOnce(continuation)
            let request = VNCoreMLRequest(model: visionModel) { request, error in
                if let error {
                    cont.resume(throwing: error)
                    return
                }
                var out: [Hit] = []
                for obs in (request.results as? [VNRecognizedObjectObservation]) ?? [] {
                    guard let label = obs.labels.first?.identifier,
                          allowed?.contains(label) != false else { continue }
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
            let stage = CameraDetailDetectorStage()
            if let detected = try? await stage.process(frame, context: context) {
                vehicleObservations = detected.observations.map {
                    CoreMLDetectorStage.observation(label: $0.label, confidence: $0.confidence, box: $0.box)
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
            // A generic detector (COCO "car"/"truck") cannot vouch for a fleet
            // class. When its label maps to a non-fleet class, keep the
            // baseline's text-inferred class (e.g. POLICE door text → .patrol)
            // instead of collapsing the vehicle to .unknown — otherwise the
            // gate loses the classifier contribution that markings earned.
            // Text inference is not a classifier score, so confidence resets.
            if !fused[index].vehicleClass.isFleet {
                let markings = SceneTextHeuristics.parse(fused[index].sceneText)
                fused[index].vehicleClass = VisionBaselineAnalyzer.vehicleClass(for: markings)
                fused[index].classConfidence = 0
            }
        }
        // Vehicles the detector missed entirely (heavy crops, unusual angles,
        // low light) still exist in the baseline as plate/markings
        // pseudo-vehicles. Keep any whose center no detector box claims, so
        // detector coverage never *reduces* what the text pipeline found.
        let claimedBoxes = fused.map(\.boundingBox)
        for missed in baselineFrame.vehicles
        where !claimedBoxes.contains(where: { $0.contains(centerOf: missed.boundingBox) }) {
            fused.append(missed)
        }
        // Fold the frame-level classifier cue exactly like the baseline: boost
        // the single candidate, or the vehicle carrying fleet text. (The
        // cue-only-append branch can add a bystander box — the baseline has
        // the same behavior and holds 100 % precision with it.)
        VisionBaselineAnalyzer.applyCue(VehicleCueClassifier.classify(frame.pixelBuffer),
                                        sceneText: baselineFrame.vehicles.first?.sceneText ?? [],
                                        to: &fused)
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
