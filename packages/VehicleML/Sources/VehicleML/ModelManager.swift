import CoreML
import CryptoKit
import Foundation

/// Downloads, verifies (SHA-256), compiles and caches CoreML models.
/// Models are registry-addressed — call sites never hardcode paths.
public actor ModelManager {

    public enum State: Sendable, Equatable {
        case notInstalled, downloading, installed(version: String), failed(String)
    }

    public struct Config: Sendable {
        /// Override for the registry URL (defaults to the upstream repo raw file).
        public var registryURL: URL
        /// Local cache root (app group container in production).
        public var cacheDirectory: URL
        /// Developer override: a model dropped here as `<task>.mlmodel` / `<task>.mlpackage` / `<task>.mlmodelc`
        /// (e.g. `plate-detection.mlmodel`) is used instead of the registry's. Lets a freshly trained model be tried
        /// on a device or the Hub with no release. Defaults to `<cacheDirectory>/Local`.
        public var localModelsDirectory: URL

        public init(registryURL: URL, cacheDirectory: URL, localModelsDirectory: URL? = nil) {
            self.registryURL = registryURL
            self.cacheDirectory = cacheDirectory
            self.localModelsDirectory = localModelsDirectory ?? cacheDirectory.appendingPathComponent("Local", isDirectory: true)
        }
    }

    public let config: Config
    private var states: [String: State] = [:]
    private var loaded: [String: MLModel] = [:]
    private let session: URLSession

    public init(config: Config, session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    public func state(of name: String) -> State { states[name] ?? .notInstalled }

    public func fetchRegistry() async throws -> ModelRegistry {
        do {
            let (data, response) = try await session.data(from: config.registryURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw ManagerError.registryUnavailable }
            let registry = try JSONDecoder().decode(ModelRegistry.self, from: data)
            try? FileManager.default.createDirectory(at: config.cacheDirectory, withIntermediateDirectories: true)
            try? data.write(to: config.cacheDirectory.appendingPathComponent("registry.json"), options: .atomic)
            return registry
        } catch {
            // A cached or bundled registry keeps already-installed models usable
            // during an offline launch. No download is started by this fallback.
            let cached = config.cacheDirectory.appendingPathComponent("registry.json")
            if let data = try? Data(contentsOf: cached), let registry = try? JSONDecoder().decode(ModelRegistry.self, from: data) {
                return registry
            }
            if let bundled = Bundle.module.url(forResource: "registry", withExtension: "json"),
               let data = try? Data(contentsOf: bundled),
               let registry = try? JSONDecoder().decode(ModelRegistry.self, from: data) {
                return registry
            }
            throw ManagerError.registryUnavailable
        }
    }

    /// Ensure the latest model for `task` is downloaded + compiled, and return
    /// it. Throws `modelMissing` when the registry has no entry (callers
    /// should treat that as "run baseline mode"). Returns a Sendable wrapper —
    /// `MLModel` is documented thread-safe but is itself non-Sendable, and
    /// raw returns across actor isolation don't compile under Swift 6.
    public func model(forTask task: String, registry: ModelRegistry) async throws -> CompiledModel {
        if let local = Self.localModelURL(forTask: task, in: config.localModelsDirectory) {
            return CompiledModel(try await loadLocal(local, task: task))
        }
        guard let entry = registry.latest(forTask: task) else {
            throw AnalysisError.modelMissing(task: task)
        }
        if let cached = loaded[entry.name] { return CompiledModel(cached) }

        let compiledURL = compiledModelURL(for: entry)
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            states[entry.name] = .downloading
            try await downloadAndCompile(entry: entry, to: compiledURL)
        }
        let model = try MLModel(contentsOf: compiledURL)
        loaded[entry.name] = model
        states[entry.name] = .installed(version: entry.version)
        return CompiledModel(model)
    }

    /// The developer-override file for `task`, if any. Preference: compiled > package > single file.
    static func localModelURL(forTask task: String, in directory: URL) -> URL? {
        for ext in ["mlmodelc", "mlpackage", "mlmodel"] {
            let url = directory.appendingPathComponent("\(task).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    /// Loads a local override, compiling `.mlmodel`/`.mlpackage` once per file modification time.
    private func loadLocal(_ url: URL, task: String) async throws -> MLModel {
        let fm = FileManager.default
        let mtime = Int(((try? fm.attributesOfItem(atPath: url.path)[.modificationDate]) as? Date)?.timeIntervalSince1970 ?? 0)
        let key = "local:\(task):\(mtime)"
        if let cached = loaded[key] { return cached }
        let model: MLModel
        if url.pathExtension == "mlmodelc" {
            model = try MLModel(contentsOf: url)
        } else {
            let compiledURL = config.cacheDirectory.appendingPathComponent("local-\(task).\(mtime).mlmodelc")
            if !fm.fileExists(atPath: compiledURL.path) {
                try fm.createDirectory(at: config.cacheDirectory, withIntermediateDirectories: true)
                let compiled = try await MLModel.compileModel(at: url)
                try fm.moveItem(at: compiled, to: compiledURL)
            }
            model = try MLModel(contentsOf: compiledURL)
        }
        loaded[key] = model
        states[task] = .installed(version: "local")
        return model
    }

    private func downloadAndCompile(entry: ModelRegistryEntry, to compiledURL: URL) async throws {
        // CoreML compiles by file extension, so the temporary artifact must carry the right one.
        let tmpZip = config.cacheDirectory.appendingPathComponent("\(entry.name).\(entry.artifactExtension)")
        let (fileURL, response) = try await session.download(from: entry.url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ManagerError.downloadFailed(entry.url)
        }
        let fm = FileManager.default
        try fm.createDirectory(at: config.cacheDirectory, withIntermediateDirectories: true)
        if fm.fileExists(atPath: tmpZip.path) { try fm.removeItem(at: tmpZip) }
        try fm.moveItem(at: fileURL, to: tmpZip)

        // Pin integrity before any compile/execute step.
        let digest = SHA256.hash(data: try Data(contentsOf: tmpZip))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        guard hex.lowercased() == entry.sha256.lowercased() else {
            try? fm.removeItem(at: tmpZip)
            states[entry.name] = .failed("sha256 mismatch")
            throw ManagerError.integrityCheckFailed(entry.name)
        }

        // `.aar` entries (a .mlpackage is a directory) are unpacked in isolation first; single files compile directly.
        var modelSource = tmpZip
        var workDirectory: URL?
        if entry.artifactExtension == "aar" {
            let work = config.cacheDirectory.appendingPathComponent("extract-\(UUID().uuidString)", isDirectory: true)
            workDirectory = work
            modelSource = try ModelArchive.extractIsolated(archiveAt: tmpZip, workDirectory: work)
        }
        defer {
            try? fm.removeItem(at: tmpZip)
            if let workDirectory { try? fm.removeItem(at: workDirectory) }
        }
        let compiled = try await MLModel.compileModel(at: modelSource)
        if fm.fileExists(atPath: compiledURL.path) { try fm.removeItem(at: compiledURL) }
        try fm.moveItem(at: compiled, to: compiledURL)
    }

    private func compiledModelURL(for entry: ModelRegistryEntry) -> URL {
        config.cacheDirectory
            .appendingPathComponent(entry.name)
            .appendingPathExtension(entry.version)
            .appendingPathExtension("mlmodelc")
    }

    public enum ManagerError: Error {
        case registryUnavailable
        case downloadFailed(URL)
        case integrityCheckFailed(String)
    }
}

/// Sendable handle to a compiled CoreML model. `MLModel` is thread-safe for
/// concurrent prediction (documented by Apple) but is not itself Sendable.
public struct CompiledModel: @unchecked Sendable {
    public let mlModel: MLModel
    public init(_ mlModel: MLModel) { self.mlModel = mlModel }
}
