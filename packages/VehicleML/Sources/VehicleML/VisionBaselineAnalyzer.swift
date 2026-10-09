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
            in: pixelBuffer, level: .fast, languageCorrection: false)

        // Split scene text from plate-shaped text (no VN types retained).
        struct PlateHypothesis: Sendable { var box: CGRect }
        var sceneText: [SceneTextObservation] = []
        var hypotheses: [PlateHypothesis] = []
        for hit in fastHits {
            let text = hit.texts.first ?? ""
            let aspect = Double(hit.box.width / max(hit.box.height, 0.0001))
            let normalized = Plate.normalize(text)
            let looksLikePlate = plateAspectRange.contains(aspect)
                && (3...8).contains(normalized.count)
            if looksLikePlate {
                hypotheses.append(PlateHypothesis(box: hit.box))
            } else {
                sceneText.append(SceneTextObservation(
                    text: text,
                    boundingBox: NormalizedBox(visionRect: hit.box),
                    confidence: Double(hit.confidence)))
            }
        }

        // Accurate re-read per plate crop. Sequential by design: plate
        // candidates per frame are few, and contention on the ANE would
        // dominate any parallelism win.
        var plates: [PlateObservation] = []
        for hypothesis in hypotheses {
            if let plate = try await accuratePlateRead(hypothesis.box, in: pixelBuffer) {
                plates.append(plate)
            }
        }
        plates.sort { ($0.best?.confidence ?? 0) > ($1.best?.confidence ?? 0) }

        // Baseline mode carries no vehicle detector: the plate regions define
        // pseudo-vehicle observations; the CoreML pipeline replaces this.
        let vehicles = plates.map { plate in
            VehicleObservation(
                boundingBox: plate.boundingBox.expanded(by: 6),
                vehicleClass: .unknown,
                classConfidence: 0,
                plates: [plate],
                sceneText: sceneText)
        }

        return DetectionFrame(timestamp: context.timestamp,
                              imageSize: CGSize(width: width, height: height),
                              vehicles: vehicles)
    }

    private func accuratePlateRead(_ box: CGRect, in pixelBuffer: CVPixelBuffer) async throws -> PlateObservation? {
        let cropBox = box.insetBy(dx: -box.width * 0.1, dy: -box.height * 0.35)
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
