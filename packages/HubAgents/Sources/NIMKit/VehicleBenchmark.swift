import Foundation

public struct ResearchBox: Codable, Sendable, Equatable {
    /// Normalized top-left x/y and width/height, as in the provider's pixel xywh boxes.
    public let x: Double, y: Double, width: Double, height: Double
    public init(x: Double, y: Double, width: Double, height: Double) throws {
        guard [x,y,width,height].allSatisfy(\.isFinite), x >= 0, y >= 0, width > 0, height > 0,
              x + width <= 1.000001, y + height <= 1.000001 else { throw NIMError.invalidInput }
        self.x = x; self.y = y; self.width = width; self.height = height
    }
    public static func annotations(_ text: String) throws -> [Self] {
        guard text.utf8.count <= 20_000, let data = text.data(using: .utf8),
              let rows = try? JSONDecoder().decode([[Double]].self, from: data), rows.count <= 200 else { throw NIMError.invalidInput }
        return try rows.map { row in
            guard row.count == 4 else { throw NIMError.invalidInput }
            return try .init(x: row[0], y: row[1], width: row[2], height: row[3])
        }
    }
    func iou(_ other: Self) -> Double {
        let intersection = max(0, min(x + width, other.x + other.width) - max(x, other.x)) * max(0, min(y + height, other.y + other.height) - max(y, other.y))
        return intersection / (width * height + other.width * other.height - intersection)
    }
}
public struct ResearchDetection: Codable, Sendable {
    public let label: String
    public let confidence: Double?
    public let box: ResearchBox
}
public struct VehicleBenchmarkResult: Codable, Sendable {
    public let matched: Int, missed: Int
    public let unmatchedPredictions: Int
    public let precision: Double?
    public let recall: Double?
    public let meanMatchedIoU: Double?
    public let iouThreshold: Double
    public let exhaustive: Bool
}
public enum VehicleResearchBenchmark {
    /// Current hosted VLM response. No confidence is invented for model-generated boxes.
    public static func decodeVLM(_ data: Data) throws -> [ResearchDetection] {
        struct Payload: Decodable { struct Detection: Decodable { let label: String; let box: ResearchBox }; let detections: [Detection] }
        let text = try NIMClient.chatText(data)
        guard let payload = try? JSONDecoder().decode(Payload.self, from: Data(text.utf8)), payload.detections.count <= 32 else { throw NIMError.invalidResponse }
        return try payload.detections.map { item in
            guard ["car", "suv", "truck", "bus", "motorcycle"].contains(item.label.lowercased()) else { throw NIMError.invalidResponse }
            let box = try ResearchBox(x: item.box.x, y: item.box.y, width: item.box.width, height: item.box.height)
            return .init(label: item.label, confidence: nil, box: box)
        }
    }
    /// Schema from NVIDIA's Grounding DINO reference: choice.message.content.boundingBoxes.
    public static func decode(_ data: Data) throws -> [ResearchDetection] {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    struct Content: Decodable {
                        struct Boxes: Decodable { let phrase: String; let bboxes: [[Double]]; let confidence: [Double] }
                        let frameWidth: Double, frameHeight: Double
                        let boundingBoxes: [Boxes]
                    }
                    let content: Content
                }
                let message: Message
            }
            let choices: [Choice]
        }
        guard data.count <= 1_000_000, let response = try? JSONDecoder().decode(Response.self, from: data), response.choices.count == 1,
              let content = response.choices.first?.message.content,
              content.frameWidth > 0, content.frameHeight > 0, content.frameWidth <= 100_000, content.frameHeight <= 100_000 else { throw NIMError.invalidResponse }
        var result: [ResearchDetection] = []
        for group in content.boundingBoxes {
            guard group.phrase.utf8.count <= 200, group.bboxes.count == group.confidence.count, result.count + group.bboxes.count <= 200 else { throw NIMError.invalidResponse }
            for (box, confidence) in zip(group.bboxes, group.confidence) {
                guard box.count == 4, confidence.isFinite, (0...1).contains(confidence) else { throw NIMError.invalidResponse }
                let normalized = try ResearchBox(x: box[0] / content.frameWidth, y: box[1] / content.frameHeight,
                    width: box[2] / content.frameWidth, height: box[3] / content.frameHeight)
                result.append(.init(label: group.phrase, confidence: confidence, box: normalized))
            }
        }
        return result
    }
    public static func score(expected: [ResearchBox], predictions: [ResearchDetection], exhaustive: Bool, threshold: Double = 0.5) throws -> VehicleBenchmarkResult {
        guard threshold > 0, threshold <= 1, expected.count <= 200, predictions.count <= 200 else { throw NIMError.invalidInput }
        // Validate even values supplied through Codable, which bypasses the throwing initializer.
        for box in expected + predictions.map(\.box) { _ = try ResearchBox(x: box.x, y: box.y, width: box.width, height: box.height) }
        guard predictions.allSatisfy({ $0.confidence.map { $0.isFinite && (0...1).contains($0) } ?? true }) else { throw NIMError.invalidInput }
        var remaining = Set(expected.indices), overlaps: [Double] = []
        for (_, prediction) in predictions.enumerated().sorted(by: {
            let left = $0.element.confidence ?? 1, right = $1.element.confidence ?? 1
            return left == right ? $0.offset < $1.offset : left > right
        }) {
            let best = remaining.sorted().map { ($0, prediction.box.iou(expected[$0])) }.max { $0.1 < $1.1 }
            if let best, best.1 >= threshold { remaining.remove(best.0); overlaps.append(best.1) }
        }
        return .init(matched: overlaps.count, missed: remaining.count, unmatchedPredictions: predictions.count - overlaps.count,
            precision: exhaustive && !predictions.isEmpty ? Double(overlaps.count) / Double(predictions.count) : nil,
            recall: expected.isEmpty ? nil : Double(overlaps.count) / Double(expected.count),
            meanMatchedIoU: overlaps.isEmpty ? nil : overlaps.reduce(0,+) / Double(overlaps.count), iouThreshold: threshold, exhaustive: exhaustive)
    }
}
