import CryptoKit
import Foundation
import ImageIO

/// A second local copy of Review JPEGs. The hash locates and verifies bytes;
/// it cannot recreate an image if both copies are lost.
struct EvidenceArchive: Sendable {
    let directory: URL

    static var current: Self {
        #if DEBUG
        if CommandLine.arguments.contains("-PWVisualQA") {
            return Self(directory: FileManager.default.temporaryDirectory
                .appendingPathComponent("PlateWatchVisualQA/Evidence", isDirectory: true))
        }
        #endif
        return Self(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlateWatchHub/Evidence", isDirectory: true))
    }

    enum ArchiveError: Error { case invalidImageOrHash }

    func store(_ data: Data, hash: String) throws {
        guard let name = canonicalHash(hash), validJPEG(data), digest(data) == name else {
            throw ArchiveError.invalidImageOrHash
        }
        if load(hash: name) != nil { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        let url = directory.appendingPathComponent(name + ".jpg")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    func load(hash: String) -> Data? {
        guard let name = canonicalHash(hash) else { return nil }
        let url = directory.appendingPathComponent(name + ".jpg")
        guard let info = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              info.isRegularFile == true, info.isSymbolicLink != true,
              let size = info.fileSize, size > 0, size <= EvidenceCrop.maxBytes,
              let data = try? Data(contentsOf: url), validJPEG(data), digest(data) == name else { return nil }
        return data
    }

    /// Accept legacy inline images without hashes, but use an archive fallback
    /// when an integrity-checked inline payload is missing or damaged.
    func resolve(base64: String?, hash: String?) -> Data? {
        if let base64, base64.utf8.count <= 54_000,
           let data = Data(base64Encoded: base64), validJPEG(data),
           hash == nil || canonicalHash(hash!) == digest(data) { return data }
        return hash.flatMap { load(hash: $0) }
    }

    func remove(hash: String) {
        guard let name = canonicalHash(hash) else { return }
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(name + ".jpg"))
    }

    private func canonicalHash(_ hash: String) -> String? {
        let name = hash.lowercased()
        guard name.utf8.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return name
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func validJPEG(_ data: Data) -> Bool {
        guard !data.isEmpty, data.count <= EvidenceCrop.maxBytes,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetType(source) as String? == "public.jpeg",
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width <= 640, height <= 640 else { return false }
        return CGImageSourceCreateImageAtIndex(source, 0, nil) != nil
    }
}
