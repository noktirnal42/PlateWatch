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

        public init(registryURL: URL, cacheDirectory: URL) {
            self.registryURL = registryURL
            self.cacheDirectory = cacheDirectory
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
        let (data, response) = try await session.data(from: config.registryURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ManagerError.registryUnavailable
        }
        return try JSONDecoder().decode(ModelRegistry.self, from: data)
    }

    /// Ensure the latest model for `task` is downloaded + compiled, and return
    /// it. Throws `modelMissing` when the registry has no entry (callers
    /// should treat that as "run baseline mode").
    public func model(forTask task: String, registry: ModelRegistry) async throws -> MLModel {
        guard let entry = registry.latest(forTask: task) else {
            throw AnalysisError.modelMissing(task: task)
        }
        if let cached = loaded[entry.name] { return cached }

        let compiledURL = compiledModelURL(for: entry)
        if !FileManager.default.fileExists(atPath: compiledURL.path) {
            states[entry.name] = .downloading
            try await downloadAndCompile(entry: entry, to: compiledURL)
        }
        let model = try MLModel(contentsOf: compiledURL)
        loaded[entry.name] = model
        states[entry.name] = .installed(version: entry.version)
        return model
    }

    private func downloadAndCompile(entry: ModelRegistryEntry, to compiledURL: URL) async throws {
        let tmpZip = config.cacheDirectory.appendingPathComponent("\(entry.name).download")
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

        // The registry ships raw .mlpackage directories (unzipped by the
        // packager into a folder) — compile to .mlmodelc for runtime.
        let modelFolder = tmpZip // rename for clarity; a real pack ships .mlpackage
        let compiled = try await MLModel.compileModel(at: modelFolder)
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
