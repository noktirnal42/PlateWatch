@preconcurrency import CoreML
import Foundation
import PlateKit

/// Shared context passed to every stage in a run.
/// @unchecked Sendable: `MLModel` is thread-safe for concurrent prediction
/// (documented by Apple); the dictionary is only mutated during setup.
public struct AnalysisContext: @unchecked Sendable {
    /// Resolved, compiled models available this run (empty = baseline mode).
    public var models: [String: MLModel]
    public var timestamp: Date

    public init(models: [String: MLModel] = [:], timestamp: Date = Date()) {
        self.models = models
        self.timestamp = timestamp
    }
}

/// A composable analysis stage. Community detectors/classifiers plug in here.
public protocol AnalysisStage: Sendable {
    associatedtype Input: Sendable
    associatedtype Output: Sendable
    var name: String { get }
    func process(_ input: Input, context: AnalysisContext) async throws -> Output
}

/// Thrown when a stage's required model is not downloaded/compiled.
public enum AnalysisError: Error {
    case modelMissing(task: String)
    case visionRequestFailed(String)
    case imageRequestFailed
}
