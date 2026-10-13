import Foundation
import PlateKit
import VideoToolbox
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
                          maxCandidates: Int = 1,
                          minimumTextHeight: Float = 0) async throws -> [RawTextHit] {
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
            // Vision skips text shorter than ~1/32 of the image height by default —
            // exactly the size of door lettering and plates on a full-frame vehicle.
            if minimumTextHeight > 0 { request.minimumTextHeight = minimumTextHeight }
            if let regionOfInterest { request.regionOfInterest = regionOfInterest }
            let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
            do { try handler.perform([request]) }
            catch { cont.resume(throwing: AnalysisError.visionRequestFailed(error.localizedDescription)) }
        }
    }
}

extension VisionTextRunner {
    /// Same as `recognize(in:)` but over a CGImage (a tile crop).
    static func recognize(in image: CGImage,
                          level: VNRequestTextRecognitionLevel,
                          minimumTextHeight: Float = 0) async throws -> [RawTextHit] {
        try await withCheckedThrowingContinuation { cont in
            let request = VNRecognizeTextRequest { request, error in
                if let error { cont.resume(throwing: error); return }
                cont.resume(returning: ((request.results as? [VNRecognizedTextObservation]) ?? []).map {
                    RawTextHit(texts: $0.topCandidates(1).map(\.string), confidence: $0.confidence, box: $0.boundingBox)
                })
            }
            request.recognitionLevel = level
            request.usesLanguageCorrection = false
            request.recognitionLanguages = ["en-US"]
            if minimumTextHeight > 0 { request.minimumTextHeight = minimumTextHeight }
            do { try VNImageRequestHandler(cgImage: image, options: [:]).perform([request]) }
            catch { cont.resume(throwing: AnalysisError.visionRequestFailed(error.localizedDescription)) }
        }
    }

    /// Overlapping 2×2 tiles. Vision downsamples a large frame before reading,
    /// so door lettering and plates that are small in a full-vehicle photo get
    /// lost; cropping makes the same text larger relative to the request.
    /// Results are mapped back to full-image Vision coordinates.
    static func recognizeTiled(in pixelBuffer: CVPixelBuffer, minimumTextHeight: Float) async -> [RawTextHit] {
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cg)
        guard let image = cg else { return [] }
        let w = Double(image.width), h = Double(image.height)
        let size = 0.6
        var out: [RawTextHit] = []
        for ty in [0.0, 0.4] {          // Vision space: origin bottom-left
            for tx in [0.0, 0.4] {
                let crop = CGRect(x: tx * w, y: (1 - ty - size) * h, width: size * w, height: size * h)
                guard let tile = image.cropping(to: crop),
                      let hits = try? await recognize(in: tile, level: .accurate,
                                                      minimumTextHeight: minimumTextHeight) else { continue }
                for hit in hits {
                    let box = CGRect(x: tx + Double(hit.box.minX) * size, y: ty + Double(hit.box.minY) * size,
                                     width: Double(hit.box.width) * size, height: Double(hit.box.height) * size)
                    out.append(RawTextHit(texts: hit.texts, confidence: hit.confidence, box: box))
                }
            }
        }
        return out
    }

    /// Drop tile hits that repeat something the full-frame pass already found.
    static func merge(_ base: [RawTextHit], with extra: [RawTextHit]) -> [RawTextHit] {
        var merged = base
        for hit in extra {
            let text = (hit.texts.first ?? "").uppercased()
            let duplicate = merged.contains { other in
                let same = (other.texts.first ?? "").uppercased() == text
                let inter = other.box.intersection(hit.box)
                guard !inter.isNull else { return false }
                let union = other.box.width * other.box.height + hit.box.width * hit.box.height
                    - inter.width * inter.height
                return same && union > 0 && inter.width * inter.height / union > 0.25
            }
            if !duplicate { merged.append(hit) }
        }
        return merged
    }
}

/// Finds plate-shaped rectangles and reads each crop on its own. A plate is a
/// small, high-contrast rectangle (~2:1); reading it as a tight crop makes its
/// characters large relative to the request, which the full-scene text pass
/// cannot do. Stills only — it runs several extra Vision requests.
enum PlateRectangleReader {

    static func read(_ pixelBuffer: CVPixelBuffer, detectorBoxes: [CGRect] = []) async -> [PlateObservation] {
        var cg: CGImage?
        VTCreateCGImageFromCVPixelBuffer(pixelBuffer, options: nil, imageOut: &cg)
        guard let image = cg else { return [] }
        let w = Double(image.width), h = Double(image.height)

        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 0.25      // height / width (Vision convention)
        request.maximumAspectRatio = 0.7
        request.minimumSize = 0.015
        request.minimumConfidence = 0.4
        request.quadratureTolerance = 25
        request.maximumObservations = 40
        guard (try? VNImageRequestHandler(cgImage: image, options: [:]).perform([request])) != nil else { return [] }

        var found: [PlateObservation] = []
        var seen = Set<String>()
        // Detector boxes are trusted (no aspect filter); rectangles must look like a plate.
        let candidates: [CGRect] = detectorBoxes
            + (request.results ?? []).map(\.boundingBox).filter {
                (1.5...3.4).contains(($0.width * w) / max($0.height * h, 1))
            }
        for box in candidates {        // Vision space, bottom-left origin
            // Pad a little so edge characters are not clipped.
            let padded = box.insetBy(dx: -box.width * 0.06, dy: -box.height * 0.12)
                .intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
            let crop = CGRect(x: padded.minX * w, y: (1 - padded.maxY) * h,
                              width: padded.width * w, height: padded.height * h)
            guard let tile = image.cropping(to: crop),
                  let hits = try? await VisionTextRunner.recognize(in: tile, level: .accurate,
                                                                   minimumTextHeight: 0.18) else { continue }
            // Join everything read inside the plate (state name, number, slogan);
            // the plausible-reading filter picks the registration.
            // Official-use plate: judge the crop's lines together ("Massachusetts /
            // POLICE D756 / OFFICIAL"), since the words and registration are separate
            // lines — but try each line on its own first: word-only plates
            // ("MINNESOTA" / "POLICE" / "10,000 LAKES") are cleaner per line, and
            // per-line judgment keeps slogan words out of the joined leftover.
            let lines = hits.compactMap { $0.texts.first }
            let officialCandidates = (lines + [lines.joined(separator: " ")]).compactMap {
                Plate.officialRegistration(from: $0, allowWordRegistration: true)
            }
            if let official = officialCandidates.first,
               seen.insert(official.registration).inserted {
                found.append(PlateObservation(
                    boundingBox: NormalizedBox(visionRect: box),
                    candidates: [Plate(text: official.registration,
                                       issuingRegion: official.jurisdiction.flatMap(Plate.issuingRegion(forStateName:)),
                                       plateDesign: official.design, confidence: 0.9)]))
                continue
            }
            for hit in hits {
                let text = hit.texts.first ?? ""
                let normalized = Plate.normalize(text)
                guard Plate.isPlausibleReading(normalized), seen.insert(normalized).inserted else { continue }
                found.append(PlateObservation(
                    boundingBox: NormalizedBox(visionRect: box),
                    candidates: [Plate(text: text, confidence: min(0.9, Double(hit.confidence) * 0.85))]))
            }
        }
        return found
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
    /// Smallest text, as a fraction of image height, read on stills.
    static let thoroughMinimumTextHeight: Float = 0.008

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

        var fastHits = try await VisionTextRunner.recognize(
            in: pixelBuffer, level: context.thorough ? .accurate : .fast, languageCorrection: false,
            minimumTextHeight: context.thorough ? Self.thoroughMinimumTextHeight : 0)

        if context.thorough {
            let tiled = await VisionTextRunner.recognizeTiled(
                in: pixelBuffer, minimumTextHeight: Self.thoroughMinimumTextHeight)
            fastHits = VisionTextRunner.merge(fastHits, with: tiled)
        }

        // Split scene text from plate-shaped text (no VN types retained).
        struct PlateHypothesis: Sendable { var box: CGRect }
        var sceneText: [SceneTextObservation] = []
        var hypotheses: [PlateHypothesis] = []
        var officialPlates: [PlateObservation] = []
        for hit in fastHits {
            let text = hit.texts.first ?? ""
            let aspect = Double(hit.box.width / max(hit.box.height, 0.0001))
            let normalized = Plate.normalize(text)
            // "POLICE D756" / "…OFFICIAL": an official-use plate. It becomes a plate
            // (registration "D756", design government-official), never agency text.
            if let official = Plate.officialRegistration(from: text) {
                officialPlates.append(PlateObservation(
                    boundingBox: NormalizedBox(visionRect: hit.box),
                    candidates: [Plate(text: official.registration,
                                       issuingRegion: official.jurisdiction.flatMap(Plate.issuingRegion(forStateName:)),
                                       plateDesign: official.design,
                                       confidence: 0.9)]))
                continue
            }
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
                && Plate.isPlausibleReading(normalized) // not a brand word, slogan or asset ID
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
        let detectorBoxes = await Self.plateDetectorBoxes(context, pixelBuffer)
        if context.thorough || !detectorBoxes.isEmpty {
            let known = Set(plates.compactMap { $0.best.map { Plate.normalize($0.text) } })
            for extra in await PlateRectangleReader.read(pixelBuffer, detectorBoxes: detectorBoxes)
            where !known.contains(Plate.normalize(extra.best?.text ?? "")) {
                plates.append(extra)
            }
        }
        for official in officialPlates
        where !plates.contains(where: { Plate.normalize($0.best?.text ?? "") == official.best?.text }) {
            plates.append(official)
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

    /// Plate boxes (Vision space) from the optional CoreML plate detector.
    static func plateDetectorBoxes(_ context: AnalysisContext, _ pixelBuffer: CVPixelBuffer) async -> [CGRect] {
        guard context.models["plate-detection"] != nil,
              let detected = try? await CoreMLDetectorStage(task: "plate-detection")
                .process(FramePacketLike(pixelBuffer: pixelBuffer), context: context) else { return [] }
        return detected.observations
            .filter { $0.label.lowercased().contains("plate") || $0.label == "0" }
            .map { CGRect(x: $0.box.x, y: 1 - ($0.box.y + $0.box.height), width: $0.box.width, height: $0.box.height) }
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
            // The frame's only candidate.
            if !vehicles[0].vehicleClass.isFleet { vehicles[0].vehicleClass = cue.vehicleClass }
            vehicles[0].classConfidence = max(vehicles[0].classConfidence, cue.confidence)
            return
        }
        // Several candidates: the cue belongs to the one with fleet text on it.
        if let marked = vehicles.firstIndex(where: { SceneTextHeuristics.parse($0.sceneText).hasFleetKeyword
                                                      && $0.vehicleClass.isFleet }) {
            vehicles[marked].classConfidence = max(vehicles[marked].classConfidence, cue.confidence)
            return
        }
        // Otherwise a separate, plate-free vehicle: a bystander's plate never
        // rides along on a frame-level cue.
        if cue.confidence >= 0.5, !vehicles.contains(where: { $0.vehicleClass.isFleet && $0.plates.isEmpty }) {
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
            guard Plate.isPlausibleReading(normalized) else { continue }
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
