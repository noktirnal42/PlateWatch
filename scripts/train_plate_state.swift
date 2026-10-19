// Headless Create ML baseline for the plate-state (design) classifier — docs/PLATE-STATE-CLASSIFIER-SPEC.md §5.1.
//
// Usage: swiftc -O scripts/train_plate_state.swift -o /tmp/train_plate_state
//        /tmp/train_plate_state <dataset dir with train|validation|test> <out dir> [images to predict ...]
// Writes <out>/PlateState.mlmodel and <out>/report.json (accuracy, per-class recall). Weights are never committed.
import CreateML
import Foundation

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: train_plate_state <dataset> <out> [images...]"); exit(2) }
let dataset = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

let train = MLImageClassifier.DataSource.labeledDirectories(at: dataset.appendingPathComponent("train"))
let validation = MLImageClassifier.DataSource.labeledDirectories(at: dataset.appendingPathComponent("validation"))
let test = MLImageClassifier.DataSource.labeledDirectories(at: dataset.appendingPathComponent("test"))

let params = MLImageClassifier.ModelParameters(
    validation: .dataSource(validation),
    maxIterations: 25,
    augmentation: [.crop, .blur, .exposure, .noise, .rotation],
    algorithm: .transferLearning(featureExtractor: .scenePrint(revision: 2), classifier: .logisticRegressor))
let classifier = try MLImageClassifier(trainingData: train, parameters: params)

let trainAcc = 100 * (1 - classifier.trainingMetrics.classificationError)
let valAcc = 100 * (1 - classifier.validationMetrics.classificationError)
let metrics = classifier.evaluation(on: test)
let testAcc = 100 * (1 - metrics.classificationError)
print(String(format: "train %.1f%%  validation %.1f%%  test %.1f%%", trainAcc, valAcc, testAcc))

// Per-class recall from the confusion table.
var recall: [String: Double] = [:]
var correct: [String: Int] = [:], total: [String: Int] = [:]
for row in metrics.confusion.rows {
    if let t = row["True Label"]?.stringValue, let p = row["Predicted"]?.stringValue, let n = row["Count"]?.intValue {
        total[t, default: 0] += n
        if t == p { correct[t, default: 0] += n }
    }
}
for (k, v) in total where v > 0 { recall[k] = Double(correct[k, default: 0]) / Double(v) }

try classifier.write(to: out.appendingPathComponent("PlateState.mlmodel"),
                     metadata: MLModelMetadata(author: "PlateWatch", shortDescription: "US plate state from plate design (baseline)",
                                               license: "See training manifest; weights are not committed", version: "baseline-0"))
let report: [String: Any] = ["train": trainAcc, "validation": valAcc, "test": testAcc,
                             "testCount": total.values.reduce(0, +), "perClassTestRecall": recall]
try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("report.json"))

for path in args.dropFirst(3) {
    do {
        let labels = try classifier.predictions(from: [URL(fileURLWithPath: path)])
        print("\((path as NSString).lastPathComponent): \(labels)")
    } catch { print("\(path): \(error)") }
}
