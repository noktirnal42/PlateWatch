import CryptoKit
import Foundation

/// Read-only adaptation of Axiom's standard Hugging Face cache layout.
/// No downloads, shared-file deletion, fallback creation or machine-specific path.
public struct SharedModelStore: Sendable {
    public static let repo = "mlx-community/Qwen2.5-1.5B-Instruct-4bit"
    public static let revision = "8b403126fc14f14cfc99bb4cfa72ecbc129ea677"
    public static let license = "Apache-2.0"
    public let root: URL

    public init(root: URL? = nil) {
        let env = ProcessInfo.processInfo.environment
        if let root { self.root = root }
        else if let value = env["PLATEWATCH_MODEL_STORE"], !value.isEmpty { self.root = URL(fileURLWithPath: value) }
        else if let value = env["HF_HUB_CACHE"], !value.isEmpty { self.root = URL(fileURLWithPath: value) }
        else if let value = env["HF_HOME"], !value.isEmpty { self.root = URL(fileURLWithPath: value).appendingPathComponent("hub") }
        else { self.root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cache/huggingface/hub") }
    }

    public func snapshot() throws -> URL {
        let resolved = root.resolvingSymlinksInPath().standardizedFileURL
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw AgentFailure.unavailable("The shared model store is unavailable. Reconnect its volume; no replacement cache was created.")
        }
        let directory = resolved.appendingPathComponent("models--" + Self.repo.replacingOccurrences(of: "/", with: "--"))
            .appendingPathComponent("snapshots").appendingPathComponent(Self.revision)
        guard FileManager.default.fileExists(atPath: directory.appendingPathComponent("config.json").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("model.safetensors").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer.json").path),
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("tokenizer_config.json").path) else {
            throw AgentFailure.unavailable("The pinned Qwen 1.5B snapshot is not installed in the shared store. No download was started.")
        }
        return directory
    }

    /// Verify HF LFS SHA-256 blobs and git-blob SHA-1 metadata before loading.
    /// Call away from the UI actor; the model weight is streamed in 1 MiB chunks.
    public func verifiedSnapshot(cancellation: AgentCancellation) throws -> URL {
        let directory = try snapshot()
        let repository = directory.deletingLastPathComponent().deletingLastPathComponent()
        let blobs = repository.appendingPathComponent("blobs").resolvingSymlinksInPath().standardizedFileURL.path + "/"
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        guard !files.isEmpty, files.count <= 100 else { throw AgentFailure.unavailable("Model snapshot has an unexpected file layout.") }
        var total: UInt64 = 0
        for file in files {
            try cancellation.check()
            let blob = file.resolvingSymlinksInPath().standardizedFileURL
            guard blob.path.hasPrefix(blobs) else { throw AgentFailure.unavailable("A model file resolves outside its shared blob store.") }
            let name = blob.lastPathComponent.lowercased()
            guard [40, 64].contains(name.count), name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
                throw AgentFailure.unavailable("A model blob has no verifiable content hash.")
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: blob.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = (attributes[.size] as? NSNumber)?.uint64Value, size <= 1_500_000_000 else {
                throw AgentFailure.unavailable("A model blob is missing or exceeds the local model budget.")
            }
            total += size
            guard total <= 2_000_000_000 else { throw AgentFailure.unavailable("The model exceeds the local model budget.") }
            let handle = try FileHandle(forReadingFrom: blob)
            defer { try? handle.close() }
            var sha256 = SHA256(), sha1 = Insecure.SHA1()
            if name.count == 40 { sha1.update(data: Data("blob \(size)\u{0}".utf8)) }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
                try cancellation.check()
                if name.count == 64 { sha256.update(data: chunk) } else { sha1.update(data: chunk) }
            }
            let actual = name.count == 64 ? sha256.finalize().map { String(format: "%02x", $0) }.joined()
                : sha1.finalize().map { String(format: "%02x", $0) }.joined()
            guard actual == name else { throw AgentFailure.unavailable("Model integrity verification failed. The shared file was left unchanged.") }
        }
        return directory
    }
}
