import Foundation
import PlateKit
import Vision

/// Sendable snapshot of a Vision text observation. All Vision callbacks map
/// to this inside the handler so no non-Sendable VNObject crosses domains.
public struct RawTextHit: Sendable {
    public var texts: [String]   // top-N
    public var confidence: Float
    public var box: CGRect       // Vision coordinate space (bottom-left origin)
}

/// Shared Vision runner: performs one text pass and returns sendable hits.
enum VisionTextRunner {
    static func recognize(in pixelBuffer: CVPixelBuffer,
                          level: VNRequestTextRecognitionLevel,
                          languageCorrection: Bool,
                          regionOfInterest: CGRect? = nil,
                          maxCandidates: Int = 1) async throws -> [RawTextHit] {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                let hits: [RawTextHit] = ((request.results as? [VNRecognizedTextObservation]) ?? [])
                    .map { obs in
                        RawTextHit(texts: obs.topCandidates(maxCandidates).map(\.string),
                                   confidence: obs.confidence,
                                   box: obs.boundingBox)
                    }
                cont.resume(returning: hits)
            }
            request.recognitionLevel = level
            request.usesLanguageCorrection = languageCorrection
            request.recognitionLanguages = ["en-US"]
            if let regionOfInterest { request.regionOfInterest = regionOfInterest }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do { try handler.perform([request]) }
            catch { cont.resume(throwing: AnalysisError.visionRequestFailed(error.localizedDescription)) }
        }
    }
}

/// Baseline analyzer that requires **no downloaded models**: Apple Vision
/// text recognition does double duty as plate reader and fleet-markings
/// reader. Plate hypotheses are text regions whose normalized contents match
/// plate geometry (aspect ratio) and regional pattern catalogs.
///
/// Upgraded operation: when `ModelRegistry` models are installed this stage
/// is replaced by the CoreML detector+OCR stages — same output shape, better
/// recall at distance/night.
public struct VisionBaselineAnalyzer: AnalysisStage {
    public let name = "vision-baseline"

    /// Plate-like aspect ratio bounds (w/h). US ≈ 2.0; we accept a wide-ish
    /// envelope for stacked/motorcycle/other formats.
    public var plateAspectRange: ClosedRange<Double> = 1.0...4.5
    public var minimumCropConfidence: Float = 0.3

    private let candidateRegions: [String] // e.g. ["US-CA","US-TX"] biases pattern scoring

    public init(candidateRegions: [String] = []) {
        self.candidateRegions = candidateRegions
    }

    public func process(_ input: FramePacketLike, context: AnalysisContext) async throws -> DetectionFrame {
        let pixelBuffer = input.pixelBuffer
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        let fastHits = try await VisionTextRunner.recognize(
            in: pixelBuffer, level: context.thorough ? .accurate : .fast, languageCorrection: false)

        // Split scene text from plate-shaped text (no VN types retained).
        struct PlateHypothesis: Sendable { var box: CGRect }
        var sceneText: [SceneTextObservation] = []
        var hypotheses: [PlateHypothesis] = []
        for hit in fastHits {
            let text = hit.texts.first ?? ""
            let aspect = Double(hit.box.width / max(hit.box.height, 0.0001))
            let normalized = Plate.normalize(text)
            let observation = SceneTextObservation(
                text: text,
                boundingBox: NormalizedBox(visionRect: hit.box),
                confidence: Double(hit.confidence))
            // Every line is scene text: door text such as "POLICE" or
            // "UNIT 4421" is plate-shaped too, and must still reach the
            // fleet-markings parser rather than being consumed as a plate.
            sceneText.append(observation)
            let parsed = SceneTextHeuristics.parse([observation])
            let isMarking = parsed.hasFleetKeyword || parsed.unitNumber != nil
            let looksLikePlate = plateAspectRange.contains(aspect)
                && (3...8).contains(normalized.count)
                && normalized.contains(where: \.isNumber) // logos/brand words ("FALCK") are not plates
                && !isMarking
            if looksLikePlate {
                hypotheses.append(PlateHypothesis(box: hit.box))
            }
        }

        // Accurate re-read per plate crop. Sequential by design: plate
        // candidates per frame are few, and contention on the ANE would
        // dominate any parallelism win.
        var plates: [PlateObservation] = []
        for hypothesis in hypotheses {
            // One unreadable crop must not discard the rest of the frame.
            if let plate = try? await accuratePlateRead(hypothesis.box, in: pixelBuffer) {
                plates.append(plate)
            }
        }
        plates.sort { ($0.best?.confidence ?? 0) > ($1.best?.confidence ?? 0) }

        // Baseline mode carries no vehicle detector: plate regions define
        // pseudo-vehicle observations; the CoreML pipeline replaces this.
        // Door/hood text can place a fleet vehicle even when no plate is
        // legible (angle, distance, glare), so it gets its own observation.
        let markings = SceneTextHeuristics.parse(sceneText)
        let inferredClass = Self.vehicleClass(for: markings)
        var vehicles = plates.map { plate in
            VehicleObservation(
                boundingBox: plate.boundingBox.expanded(by: 6),
                vehicleClass: inferredClass,
                classConfidence: 0,
                plates: [plate],
                sceneText: sceneText)
        }
        if vehicles.isEmpty, markings.hasFleetKeyword,
           let region = Self.markingsRegion(in: sceneText) {
            vehicles.append(VehicleObservation(
                boundingBox: region,
                vehicleClass: inferredClass,
                classConfidence: 0,
                plates: [],
                sceneText: sceneText))
        }

        Self.applyCue(VehicleCueClassifier.classify(pixelBuffer), sceneText: sceneText, to: &vehicles)

        return DetectionFrame(timestamp: context.timestamp,
                              imageSize: CGSize(width: width, height: height),
                              vehicles: vehicles)
    }

    /// Fold the image-level classifier cue into the vehicle list.
    ///
    /// The cue describes the *frame*, not a particular vehicle, so it must not
    /// drag a bystander's plate into a fleet record: a cue-only vehicle carries
    /// no plates, and an existing vehicle takes the cue only when it is the
    /// frame's sole candidate (one vehicle, ≤ 1 plate).
    static func applyCue(_ cue: VehicleCue?, sceneText: [SceneTextObservation], to vehicles: inout [VehicleObservation]) {
        guard let cue else { return }
        let totalPlates = vehicles.reduce(0) { $0 + $1.plates.count }
        if vehicles.count == 1, totalPlates <= 1 {
            if !vehicles[0].vehicleClass.isFleet { vehicles[0].vehicleClass = cue.vehicleClass }
            vehicles[0].classConfidence = max(vehicles[0].classConfidence, cue.confidence)
        } else if vehicles.isEmpty, cue.confidence >= 0.5 {
            vehicles.append(VehicleObservation(
                boundingBox: NormalizedBox(x: 0.08, y: 0.14, width: 0.84, height: 0.72),
                vehicleClass: cue.vehicleClass, classConfidence: cue.confidence,
                plates: [], sceneText: sceneText))
        }
    }

    /// Class implied by door text. `classConfidence` stays 0 — this is a text
    /// inference, not a classifier score — so the gate does not count it twice.
    static func vehicleClass(for markings: FleetMarkings) -> VehicleClass {
        guard markings.hasFleetKeyword else { return .unknown }
        switch markings.serviceClassText {
        case "POLICE", "SHERIFF", "MARSHAL": return .patrol
        case "STATE TROOPER", "TROOPER", "HIGHWAY PATROL": return .highway
        case "POSTAL SERVICE", "USPS": return .federal
        case "SCHOOL BUS": return .schoolBus
        case "FIRE", "RESCUE": return .fireEngine
        case "PARAMEDIC", "AMBULANCE", "EMS": return .ambulance
        case "PUBLIC WORKS", "SANITATION": return .publicWorks
        case "TRANSIT", "METRO": return .transit
        case "PARK RANGER": return .parkRanger
        case "SCHOOL DISTRICT", "UNIFIED SCHOOL DISTRICT": return .schoolBus
        default: return .otherFleet
        }
    }

    /// A vehicle-sized box around the fleet-keyword text lines. Door text
    /// sits on the side panel, so the box is grown well beyond the text.
    static func markingsRegion(in text: [SceneTextObservation]) -> NormalizedBox? {
        let relevant = text.filter { SceneTextHeuristics.parse([$0]).hasFleetKeyword }
        guard !relevant.isEmpty else { return nil }
        let minX = relevant.map { $0.boundingBox.x }.min()!
        let minY = relevant.map { $0.boundingBox.y }.min()!
        let maxX = relevant.map { $0.boundingBox.x + $0.boundingBox.width }.max()!
        let maxY = relevant.map { $0.boundingBox.y + $0.boundingBox.height }.max()!
        let width = min(1, (maxX - minX) * 2.5), height = min(1, (maxY - minY) * 4)
        let cx = (minX + maxX) / 2, cy = (minY + maxY) / 2
        return NormalizedBox(x: max(0, min(1 - width, cx - width / 2)),
                             y: max(0, min(1 - height, cy - height / 2)),
                             width: width, height: height)
    }

    private func accuratePlateRead(_ box: CGRect, in pixelBuffer: CVPixelBuffer) async throws -> PlateObservation? {
        // Pad for context, then clamp: Vision rejects (throws on) a region of
        // interest outside the unit square, which a plate near the image edge
        // would otherwise produce — failing the whole frame.
        let cropBox = box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.35)
            .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !cropBox.isNull, cropBox.width > 0.002, cropBox.height > 0.002 else { return nil }
        let hits = try await VisionTextRunner.recognize(
            in: pixelBuffer, level: .accurate, languageCorrection: false,
            regionOfInterest: cropBox, maxCandidates: 5)

        guard let best = hits.first else { return nil }
        var seen = Set<String>()
        var candidates: [Plate] = []
        for text in best.texts {
            guard seen.insert(text).inserted else { continue }
            let normalized = Plate.normalize(text)
            guard (3...8).contains(normalized.count) else { continue }
            let patternBoost = PlatePatternCatalog.rank(normalized, regions: candidateRegions).isEmpty ? 0.0 : 0.15
            let conf = min(1, Double(best.confidence) + patternBoost)
            guard conf >= Double(minimumCropConfidence) else { continue }
            candidates.append(Plate(text: text, confidence: conf))
        }
        guard !candidates.isEmpty else { return nil }
        return PlateObservation(boundingBox: NormalizedBox(visionRect: box),
                                candidates: candidates)
    }
}

/// Anything Vision can analyze — camera frames and imported files unify here.
public struct FramePacketLike: @unchecked Sendable { // pixel buffers are reference-counted
    public let pixelBuffer: CVPixelBuffer
    public init(pixelBuffer: CVPixelBuffer) { self.pixelBuffer = pixelBuffer }
}

private extension NormalizedBox {
    /// Grow a plate box into a rough vehicle silhouette estimate (US plates
    /// sit ~1/6 of vehicle width, centered low).
    func expanded(by factor: Double) -> NormalizedBox {
        let cx = x + width / 2, cy = y + height / 2
        let w = min(width * factor, 1), h = min(height * factor, 1)
        return NormalizedBox(x: max(0, cx - w / 2), y: max(0, cy - h / 2),
                             width: w, height: h)
    }
}
