import CaptureKit
import Foundation
import PlateKit
import VehicleML

struct Entry: Decodable {
    var id: Int
    var file: String
    var `class`: String
    var expectedFleet: Bool
    var difficulty: String
    var title: String
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
}

let args = CommandLine.arguments
let evalDir = URL(fileURLWithPath: args.count > 1 ? args[1] : "eval")
let manifestURL = evalDir.appendingPathComponent("manifest.json")
let entries = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: manifestURL))
let gate = RedactionGate(config: .standard)
let pipeline = PlateAnalysisPipeline()

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
                                           context: AnalysisContext(models: [:], thorough: true))
    var best = 0.0
    var bestMarkings = FleetMarkings()
    var approved = false
    var review = false
    for vehicle in frame.vehicles {
        let markings = SceneTextHeuristics.parse(vehicle.sceneText)
        let c = gate.fleetConfidence(
            vehicleClassifierFleet: vehicle.vehicleClass.isFleet ? vehicle.classConfidence : 0,
            markings: markings, knownUnitMatch: false,
            exemptPlateDesign: vehicle.plates.contains { $0.best?.exemptDesignHint == true })
        if c >= best { best = c; bestMarkings = markings }
        switch gate.verdict(fleetConfidence: c) {
        case .persistAndSync: approved = true
        case .keepLocalOnly:
            // Evidence worth a human look: fleet text or a fleet-class cue.
            if markings.hasFleetKeyword || (vehicle.vehicleClass.isFleet && vehicle.classConfidence > 0) { review = true }
        case .discard: break
        }
    }
    let plates = frame.vehicles.flatMap(\.plates).compactMap(\.best).map { "\($0.text)(\(Int($0.confidence * 100))%)" }
    let lines = Array(Set(frame.vehicles.flatMap { $0.sceneText.map(\.text) })).sorted().prefix(14)
    outcomes.append(Outcome(
        id: entry.id, file: entry.file, cls: entry.class, expectedFleet: entry.expectedFleet,
        difficulty: entry.difficulty, predictedFleet: approved, needsReview: review && !approved, confidence: best,
        vehicles: frame.vehicles.count, plates: plates, markings: describe(bestMarkings),
        ocrLines: Array(lines), seconds: Date().timeIntervalSince(start)))
    print(String(format: "%@ #%03d %-16@ expected=%@ got=%@ conf=%.2f plates=%d %@",
                 approved == entry.expectedFleet ? "✓" : "✗", entry.id, entry.class,
                 entry.expectedFleet ? "fleet" : "other", approved ? "fleet" : "other",
                 best, plates.count, describe(bestMarkings).joined(separator: " ")))
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

let resultsDir = evalDir.appendingPathComponent("results")
try? FileManager.default.createDirectory(at: resultsDir, withIntermediateDirectories: true)
let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
try enc.encode(outcomes).write(to: resultsDir.appendingPathComponent("latest.json"))
