import CoreML
import Foundation

/// Thread-safe holder for the analysis context the pipeline reads on every frame. Detector models hot-swap
/// in as they finish installing; until then the context has no models and Vision-only analysis runs.
/// (`MLModel` is documented thread-safe for prediction but is not `Sendable`, hence the lock.)
public final class AnalysisContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _current = AnalysisContext(models: [:])

    public init() {}

    public var current: AnalysisContext {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); defer { lock.unlock() }; _current = newValue }
    }
}

extension ModelManager {

    /// Installs the detector models available for `tasks` and publishes them through `box`. Used by every app
    /// (iPhone, Hub) so they share one path. The registry fetch is best-effort: when it fails (offline, or no
    /// release published yet) developer overrides in `<cache>/Local/<task>.mlmodel` still load, and any task with
    /// neither simply stays on baseline Vision. Returns how many tasks have a CoreML model.
    @discardableResult
    public func install(tasks: [String], into box: AnalysisContextBox) async -> Int {
        let registry = (try? await fetchRegistry()) ?? ModelRegistry(entries: [])
        var models: [String: MLModel] = [:]
        for task in tasks {
            if let compiled = try? await model(forTask: task, registry: registry) {
                models[task] = compiled.mlModel
            }
        }
        var context = box.current
        context.models = models
        box.current = context
        return models.count
    }
}
