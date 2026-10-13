import CaptureKit
import CoreML
import Foundation
import PlateKit
import VehicleML

/// Optional hand-labelled truth about an image's agency ("WALTHAM POLICE", Massachusetts plate).
struct AgencyTruth: Decodable {
    var place: String?       // "Waltham"
    var state: String?       // "MA"
    var service: String?     // "Police"
}

struct Entry: Decodable {
    var id: Int
    var file: String
    var `class`: String
    var expectedFleet: Bool
    var difficulty: String
    var title: String
    var agency: AgencyTruth?     // optional ground truth
    var plates: [String]?        // optional: every clearly legible registration ([] = none visible)
}

struct Outcome: Codable {
    var id: Int
    var file: String
    var cls: String
    var expectedFleet: Bool
    var difficulty: String
    var predictedFleet: Bool
    var needsReview: Bool
    var confidence: Double
    var vehicles: Int
    var plates: [String]
    var markings: [String]
    var ocrLines: [String]
    var seconds: Double
    var identity: VehicleIdentity?
}

let args = CommandLine.arguments
let evalDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "eval")
let manifestURL = evalDir.appendingPathComponent("manifest.json")
let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifestURL))
// Optional: `--models <dir>` loads cached .mlpackage detectors (plate-detector-*, vehicle-detector-*).
var loadedModels: [String: MLModel] = [:]
if let i = args.firstIndex(of: "--models"), i + 1 < args.count {
    let dir = URL(fileURLWithPath: args[i + 1])
    // `--tasks plate-detection,vehicle-detection` limits which detectors load (default: both).
    let wanted: Set<String>? = args.firstIndex(of: "--tasks").map { Set(args[$0 + 1].split(separator: ",").map(String.init)) }
    for (file, task) in [("plate-detector-yolov8n", "plate-detection"), ("vehicle-detector-yolov8n", "vehicle-detection")]
    where wanted?.contains(task) ?? true {
        let url = dir.appendingPathComponent(file + ".mlpackage")
        if FileManager.default.fileExists(atPath: url.path),
           let compiled = try? await MLModel.compileModel(at: url),
           let model = try? MLModel(contentsOf: compiled) {
            loadedModels[task] = model
            print("loaded model \(task)")
        }
    }
}
let gate = RedactionGate(config: .standard)
let pipeline = PlateAnalysisPipeline()
let resolver = IdentityResolver()

func describe(_ m: FleetMarkings) -> [String] {
    var out: [String] = []
    if let s = m.serviceClassText { out.append("service=\(s)") }
    if let a = m.agencyText, a.uppercased() != m.serviceClassText { out.append("agency=\(a)") }
    if let u = m.unitNumber { out.append("unit=\(u)") }
    return out
}

var outcomes: [Outcome] = []
for entry in entries {
    let url = evalDir.appendingPathComponent(entry.file)
    guard let buffer = FileFrameSource.pixelBuffer(from: url) else {
        FileHandle.standardError.write(Data("cannot decode \(entry.file)\n".utf8)); continue
    }
    let start = Date()
    let frame = try await pipeline.analyze(FramePacketLike(pixelBuffer: buffer),
                                           context: AnalysisContext(models: loadedModels, thorough: true))
    // One scoring entry point for every caller (PlateKit.FleetScoring) — no hand-rolled copies.
    let outcome = FleetScoring.frameGateOutcome(gate: gate, frame: frame)
    let best = outcome.bestConfidence
    let bestMarkings = outcome.bestMarkings
    let approved = outcome.anyApproved
    let review = outcome.anyReviewable
    // The frame's primary vehicle (highest gate score; a plate breaks ties) carries the identity.
    let primary = frame.vehicles.max { a, b in
        let sa = FleetScoring.vehicleGateScore(gate: gate, vehicle: a).confidence
        let sb = FleetScoring.vehicleGateScore(gate: gate, vehicle: b).confidence
        return sa != sb ? sa < sb : (a.plates.isEmpty && !b.plates.isEmpty)
    }
    let identity = primary.map { resolver.resolve(vehicle: $0) }
    let plates = frame.vehicles.flatMap(\.plates).compactMap(\.best).map { "\($0.text)(\(Int($0.confidence * 100))%)" }
    let lines = Array(Set(frame.vehicles.flatMap { $0.sceneText.map(\.text) })).sorted().prefix(14)
    outcomes.append(Outcome(
        id: entry.id, file: entry.file, cls: entry.class, expectedFleet: entry.expectedFleet,
        difficulty: entry.difficulty, predictedFleet: approved, needsReview: review && !approved, confidence: best,
        vehicles: frame.vehicles.count, plates: plates, markings: describe(bestMarkings),
        ocrLines: Array(lines), seconds: Date().timeIntervalSince(start), identity: identity))
    print(String(format: "%@ #%03d %-16@ expected=%@ got=%@ conf=%.2f plates=%d %@",
                 approved == entry.expectedFleet ? "✓" : "✗", entry.id, entry.class,
                 entry.expectedFleet ? "fleet" : "other", approved ? "fleet" : "other",
                 best, plates.count, describe(bestMarkings).joined(separator: " ")))
    if let a = identity?.agency {
        print("      identity → \(a.name)  [\(a.agencyKey)]  conf \(String(format: "%.2f", a.confidence))"
              + (a.needsReview ? "  REVIEW" : "") + (a.alternatives.isEmpty ? "" : "  alt: \(a.alternatives.joined(separator: "; "))"))
    }
}

// ---- Scoring (standard-difficulty images; unmarked reported separately) ----
let standard = outcomes.filter { $0.difficulty == "standard" }
let tp = standard.filter { $0.expectedFleet && $0.predictedFleet }.count
let fn = standard.filter { $0.expectedFleet && !$0.predictedFleet }.count
let fp = standard.filter { !$0.expectedFleet && $0.predictedFleet }.count
let tn = standard.filter { !$0.expectedFleet && !$0.predictedFleet }.count
let precision = tp + fp == 0 ? 1 : Double(tp) / Double(tp + fp)
let recall = tp + fn == 0 ? 1 : Double(tp) / Double(tp + fn)
let platesRead = outcomes.filter { !$0.plates.isEmpty }.count
print("\n=== RESULTS (\(outcomes.count) images) ===")
print("fleet recall    : \(tp)/\(tp + fn)  (\(String(format: "%.0f", recall * 100))%)")
print("fleet precision : \(tp)/\(tp + fp)  (\(String(format: "%.0f", precision * 100))%)  false positives: \(fp)")
print("true negatives  : \(tn)/\(tn + fp)")
let reviewHits = standard.filter { $0.expectedFleet && !$0.predictedFleet && $0.needsReview }.count
let reviewFalse = standard.filter { !$0.expectedFleet && $0.needsReview }.count
print("review queue    : +\(reviewHits) fleet vehicles for human confirmation (\(reviewFalse) civilian in queue)")
print("recall incl. review: \(tp + reviewHits)/\(tp + fn)  (\(String(format: "%.0f", Double(tp + reviewHits) / Double(max(1, tp + fn)) * 100))%)")
print("images with ≥1 plate read: \(platesRead)/\(outcomes.count)")
for cls in Set(outcomes.map(\.cls)).sorted() {
    let group = outcomes.filter { $0.cls == cls }
    let hit = group.filter { $0.predictedFleet }.count
    print("  \(cls.padding(toLength: 16, withPad: " ", startingAt: 0)) flagged fleet \(hit)/\(group.count)")
}
let avg = outcomes.map(\.seconds).reduce(0, +) / Double(max(1, outcomes.count))
print(String(format: "avg analysis time: %.2fs/image", avg))

// ---- Identity scoring (images with hand-labelled agency) ----
let truths = entries.compactMap { e in e.agency.map { (e, $0) } }
if !truths.isEmpty {
    var placeOK = 0, stateOK = 0, serviceOK = 0, allOK = 0, flaggedWrong = 0, offered = 0
    print("\n=== IDENTITY (\(truths.count) labelled agencies) ===")
    for (entry, truth) in truths {
        guard let o = outcomes.first(where: { $0.id == entry.id }) else { continue }
        let a = o.identity?.agency
        func eq(_ x: String?, _ y: String?) -> Bool { (x ?? "").lowercased() == (y ?? "").lowercased() }
        let p = truth.place == nil || eq(a?.place, truth.place)
        let st = truth.state == nil || eq(a?.state, truth.state)
        let sv = truth.service == nil || eq(a?.service, truth.service)
        placeOK += p ? 1 : 0; stateOK += st ? 1 : 0; serviceOK += sv ? 1 : 0
        let wanted = "\(truth.place ?? ""), \(truth.state ?? "")"
        let isOffered = (a?.alternatives.contains(wanted) ?? false) && sv
        let ok = p && st && sv
        if !ok && isOffered { offered += 1 }
        allOK += ok ? 1 : 0
        if !ok && a != nil && a?.needsReview == false { flaggedWrong += 1 }
        print("\(ok ? "✓" : "✗") #\(entry.id) want \(truth.place ?? "-")/\(truth.state ?? "-")/\(truth.service ?? "-")"
              + "  got \(a.map { "\($0.place ?? "-")/\($0.state ?? "-")/\($0.service ?? "-") (\(String(format: "%.2f", $0.confidence)))\($0.needsReview ? " REVIEW" : "")" } ?? "nothing")")
    }
    print("agency fully correct : \(allOK)/\(truths.count)   place \(placeOK)   state \(stateOK)   service \(serviceOK)")
    print("not certain, but the right answer was OFFERED among the candidates: \(offered)")
    print("confidently WRONG (wrong and not flagged for review): \(flaggedWrong)")
}

// ---- Plate scoring (images with hand-labelled registrations) ----
let plateTruths = entries.filter { $0.plates != nil }
if !plateTruths.isEmpty {
    var expected = 0, exact = 0, falseReads = 0
    for entry in plateTruths {
        guard let o = outcomes.first(where: { $0.id == entry.id }) else { continue }
        let truth = Set((entry.plates ?? []).map { Plate.normalize($0) })
        let read = Set(o.plates.map { Plate.normalize(String($0.prefix { $0 != "(" })) })
        expected += truth.count
        exact += truth.intersection(read).count
        falseReads += read.subtracting(truth).count
    }
    print("\n=== PLATES (\(plateTruths.count) labelled images) ===")
    print("registrations read exactly: \(exact)/\(expected)   spurious reads: \(falseReads)")
}

let resultsDir = evalDir.appendingPathComponent("results")
try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(outcomes).write(to: resultsDir.appendingPathComponent("latest.json"))
