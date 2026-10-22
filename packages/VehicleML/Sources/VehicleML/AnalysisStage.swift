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
    /// Stills (photo import, shutter) can afford `.accurate` text recognition;
    /// live frames stay on `.fast` to keep the camera responsive and cool.
    public var thorough: Bool
    /// Public feeds suppress OCR in reserved camera caption bands before it becomes evidence.
    public var suppressCameraCaptions: Bool
    /// False where plate recognition must not run at all (jurisdictions that regulate ALPR use —
    /// `PlateKit.JurisdictionPolicy`). Plate detection, plate OCR and plate-shaped text are all skipped; fleet
    /// detection from lettering and appearance is unaffected.
    public var readPlates: Bool
    /// Fast overlay path for moving video: whole-frame vehicle detector plus cheap type/colour only — no text recognition,
    /// no detail tiles, no plate work. Results are for drawing boxes; they must never be used to score or record fleet hits.
    public var boxesOnly: Bool

    public init(models: [String: MLModel] = [:], timestamp: Date = Date(), thorough: Bool = false,
                readPlates: Bool = true, suppressCameraCaptions: Bool = false, boxesOnly: Bool = false) {
        self.boxesOnly = boxesOnly
        self.models = models
        self.timestamp = timestamp
        self.thorough = thorough
        self.readPlates = readPlates
        self.suppressCameraCaptions = suppressCameraCaptions
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
