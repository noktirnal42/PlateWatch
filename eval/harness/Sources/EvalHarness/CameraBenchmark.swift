import CaptureKit
import CoreML
import Foundation
import PlateKit
import VehicleML

private struct CameraBenchmarkManifest: Decodable {
    struct Frame: Decodable {
        var id: String
        var image: String
        var exhaustive: Bool
        var vehicles: [NormalizedBox]
        var fleetVehicles: [NormalizedBox]?
    }
    var frames: [Frame]
}
private struct CameraBenchmarkRow: Encodable {
    var id: String
    var exhaustive: Bool
    var whole: CameraEvaluation.Metrics
    var detail: CameraEvaluation.Metrics
    var wholeSeconds: Double
    var detailSeconds: Double
    var fleet: CameraEvaluation.Metrics?
    var fleetPipelineSeconds: Double?
}

/// Local-only labeled camera benchmark. No OCR, record creation or image export.
func runCameraBenchmark(manifestURL: URL, modelURL: URL) async throws {
    let bytes = try Data(contentsOf: manifestURL)
    guard bytes.count <= 1_048_576 else { throw CocoaError(.fileReadTooLarge) }
    let manifest = try JSONDecoder().decode(CameraBenchmarkManifest.self, from: bytes)
    guard manifest.frames.count <= 1000, Set(manifest.frames.map(\.id)).count == manifest.frames.count else { throw CocoaError(.fileReadCorruptFile) }
    let directory = manifestURL.deletingLastPathComponent().resolvingSymlinksInPath()
    let compiled = modelURL.pathExtension == "mlmodelc" ? modelURL : try await MLModel.compileModel(at: modelURL)
    let model = try MLModel(contentsOf: compiled)
    var rows: [CameraBenchmarkRow] = []
    for item in manifest.frames {
        let imageURL = directory.appendingPathComponent(item.image).resolvingSymlinksInPath()
        guard !item.image.hasPrefix("/"), !item.image.contains("://"),
              imageURL.path.hasPrefix(directory.path + "/"), let buffer = FileFrameSource.pixelBuffer(from: imageURL) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        // Validate annotations before expensive inference.
        _ = try CameraEvaluation.score(expected: item.vehicles, predictions: [], exhaustive: item.exhaustive)
        let input = FramePacketLike(pixelBuffer: buffer)
        let context = AnalysisContext(models: ["vehicle-detection":model], thorough:true, readPlates:false, suppressCameraCaptions:true)
        let start = Date()
        let whole = try await CoreMLDetectorStage(task:"vehicle-detection").process(input, context:context)
        let wholeSeconds = Date().timeIntervalSince(start)
        let detailStart = Date()
        let detail = try await CameraDetailDetectorStage().process(input, context:context)
        let detailSeconds = Date().timeIntervalSince(detailStart)
        var fleet: CameraEvaluation.Metrics?
        var fleetSeconds: Double?
        if let fleetTruth = item.fleetVehicles {
            let pipelineStart = Date()
            let frame = try await PlateAnalysisPipeline().analyze(input, context: context)
            let gate = RedactionGate(config: .standard)
            let approved = frame.vehicles.compactMap { vehicle -> CameraEvaluation.Prediction? in
                let score = FleetScoring.vehicleGateScore(gate: gate, vehicle: vehicle).confidence
                guard gate.verdict(fleetConfidence: score) == .persistAndSync else { return nil }
                return .init(box: vehicle.boundingBox, confidence: score)
            }
            fleet = try CameraEvaluation.score(expected: fleetTruth, predictions: approved, exhaustive: item.exhaustive)
            fleetSeconds = Date().timeIntervalSince(pipelineStart)
        }
        func score(_ value: CoreMLDetectorStage.DetectedObjects) throws -> CameraEvaluation.Metrics {
            try CameraEvaluation.score(expected:item.vehicles, predictions:value.observations.map { .init(box:$0.box,confidence:$0.confidence) }, exhaustive:item.exhaustive)
        }
        rows.append(.init(id:item.id, exhaustive:item.exhaustive, whole:try score(whole), detail:try score(detail),
                          wholeSeconds:wholeSeconds, detailSeconds:detailSeconds, fleet:fleet, fleetPipelineSeconds:fleetSeconds))
    }
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted,.sortedKeys]
    print(String(decoding: try encoder.encode(rows), as: UTF8.self))
}
