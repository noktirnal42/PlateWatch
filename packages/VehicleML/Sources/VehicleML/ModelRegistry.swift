import Foundation

/// One entry in `models/registry.json` — the contract between this codebase,
/// the conversion script, and the CDN that hosts compiled models.
public struct ModelRegistryEntry: Sendable, Codable, Hashable {
    /// Registry name, e.g. "plate-detector-yolov9t-384". Never a file path.
    public let name: String
    /// Task identifier linking to pipeline stages, e.g. "plate-detection".
    public let task: String
    public let version: String
    /// Download URL for the zipped .mlpackage (or base64-free .mlmodel).
    public let url: URL
    /// SHA-256 of the downloaded artifact, pinned at conversion time.
    public let sha256: String
    /// Upstream project + license — AGPL-compatible sources only (see AGENTS.md).
    public let sourceURL: URL?
    public let license: String
    /// Human-readable input contract ("IMAGE 384x640 BGR, letterboxed").
    public let inputDescription: String
    /// Minimum OS for this model (ANE features vary).
    public let minimumOS: String?

    public init(name: String, task: String, version: String, url: URL, sha256: String,
                sourceURL: URL? = nil, license: String, inputDescription: String,
                minimumOS: String? = nil) {
        self.name = name
        self.task = task
        self.version = version
        self.url = url
        self.sha256 = sha256
        self.sourceURL = sourceURL
        self.license = license
        self.inputDescription = inputDescription
        self.minimumOS = minimumOS
    }
}

public struct ModelRegistry: Sendable, Codable, Equatable {
    public var schemaVersion: Int
    public var entries: [ModelRegistryEntry]

    public init(schemaVersion: Int = 1, entries: [ModelRegistryEntry]) {
        self.schemaVersion = schemaVersion
        self.entries = entries
    }

    /// Latest version of a task's model.
    public func latest(forTask task: String) -> ModelRegistryEntry? {
        entries.filter { $0.task == task }
            .max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending })
    }

    /// Decode the bundled manifest.
    public static func load(bundleURL: URL) throws -> ModelRegistry {
        let data = try Data(contentsOf: bundleURL)
        return try JSONDecoder().decode(ModelRegistry.self, from: data)
    }
}
