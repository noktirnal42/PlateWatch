import Foundation
import PlateKit

/// Offline geometry scoring. Partial annotations can measure target coverage,
/// but cannot establish precision: unmatched predictions remain unclassified.
public enum CameraEvaluation {
    public struct Prediction: Sendable {
        public var box: NormalizedBox
        public var confidence: Double
        public init(box: NormalizedBox, confidence: Double) { self.box = box; self.confidence = confidence }
    }
    public struct Metrics: Encodable, Equatable, Sendable {
        public var truePositives: Int
        public var falseNegatives: Int
        public var unmatchedPredictions: Int
        public var falsePositives: Int?
        enum CodingKeys: CodingKey { case truePositives, falseNegatives, unmatchedPredictions, falsePositives, precision, recall }
        public func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(truePositives, forKey: .truePositives)
            try container.encode(falseNegatives, forKey: .falseNegatives)
            try container.encode(unmatchedPredictions, forKey: .unmatchedPredictions)
            try container.encodeIfPresent(falsePositives, forKey: .falsePositives)
            try container.encodeIfPresent(precision, forKey: .precision)
            try container.encodeIfPresent(recall, forKey: .recall)
        }
        public var precision: Double? {
            guard let falsePositives, truePositives + falsePositives > 0 else { return nil }
            return Double(truePositives) / Double(truePositives + falsePositives)
        }
        public var recall: Double? {
            guard truePositives + falseNegatives > 0 else { return nil }
            return Double(truePositives) / Double(truePositives + falseNegatives)
        }
    }
    public enum InvalidInput: Error { case annotation, threshold }

    public static func score(expected: [NormalizedBox], predictions: [Prediction], exhaustive: Bool,
                             minimumIoU: Double = 0.5) throws -> Metrics {
        guard minimumIoU.isFinite, minimumIoU > 0, minimumIoU <= 1 else { throw InvalidInput.threshold }
        guard expected.allSatisfy(valid) else { throw InvalidInput.annotation }
        var unmatched = Set(expected.indices), hits = 0
        // Standard detection matching: consume the highest-confidence prediction
        // first, and allow each ground-truth vehicle to be claimed only once.
        let ranked = predictions.enumerated().sorted {
            let a = $0.element.confidence.isFinite ? $0.element.confidence : -1
            let b = $1.element.confidence.isFinite ? $1.element.confidence : -1
            return a == b ? $0.offset < $1.offset : a > b
        }
        for (_, prediction) in ranked {
            guard valid(prediction.box), prediction.confidence.isFinite, (0...1).contains(prediction.confidence) else { continue }
            let best = unmatched.sorted().map { ($0, iou(expected[$0], prediction.box)) }.max { $0.1 < $1.1 }
            if let best, best.1 >= minimumIoU { unmatched.remove(best.0); hits += 1 }
        }
        let extra = predictions.count - hits
        return .init(truePositives: hits, falseNegatives: unmatched.count, unmatchedPredictions: extra,
                     falsePositives: exhaustive ? extra : nil)
    }
    public static func valid(_ box: NormalizedBox) -> Bool {
        [box.x, box.y, box.width, box.height].allSatisfy(\.isFinite)
            && box.x >= 0 && box.y >= 0 && box.width > 0 && box.height > 0
            && box.x + box.width <= 1.000001 && box.y + box.height <= 1.000001
    }
    private static func iou(_ a: NormalizedBox, _ b: NormalizedBox) -> Double {
        let intersection = max(0, min(a.x + a.width, b.x + b.width) - max(a.x, b.x))
            * max(0, min(a.y + a.height, b.y + b.height) - max(a.y, b.y))
        return intersection / max(0.000001, a.width * a.height + b.width * b.height - intersection)
    }
}
