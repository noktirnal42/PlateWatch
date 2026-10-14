import AppleArchive
import Foundation
import System

/// Extraction for CoreML models shipped as Apple Archives (`.aar`).
///
/// A `.mlpackage` is a directory, so it cannot be a single release asset.
/// `scripts/package_release.sh` packs each package with `aa archive`; this
/// module unpacks it on-device and normalizes the result so `MLModel
/// .compileModel` always sees either a `<name>.mlmodel` file or a
/// `<name>.mlpackage` directory.
///
/// Note: `aa archive -d DIR` stores DIR's *contents* at the archive root, so
/// an archive of `foo.mlpackage` extracts to `Manifest.json`/`Data/…` with no
/// wrapper directory — `normalize` detects that and reassembles the named
/// package.
public enum ModelArchive {

    public enum ArchiveError: Error {
        case extractionFailed(String)
        case modelRootNotFound
        /// The archive contained a symbolic link or wrote outside its destination.
        case unsafeContents(String)
    }

    /// Extract into a private, freshly created directory and verify nothing escaped it. The archive is untrusted
    /// (sha256-pinned, but still): any symlink entry or any file written beside the payload directory fails the
    /// extraction and the work directory is removed. Returns the model root; the caller removes `workDirectory`.
    public static func extractIsolated(archiveAt archiveURL: URL, workDirectory: URL) throws -> URL {
        let fm = FileManager.default
        try? fm.removeItem(at: workDirectory)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let payload = workDirectory.appendingPathComponent("payload", isDirectory: true)
        do {
            let root = try extract(archiveAt: archiveURL, to: payload)
            let siblings = try fm.contentsOfDirectory(atPath: workDirectory.path)
            guard siblings == ["payload"] else { throw ArchiveError.unsafeContents("entries outside payload: \(siblings)") }
            return root
        } catch {
            try? fm.removeItem(at: workDirectory)
            throw error
        }
    }

    /// Throws if `root` contains any symbolic link.
    static func rejectSymlinks(under root: URL) throws {
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            throw ArchiveError.unsafeContents("symlink: \(url.lastPathComponent)")
        }
    }

    /// Extract `archiveURL` into `destination` and return the model root
    /// (a `.mlmodel` file or `.mlpackage` directory) ready for
    /// `MLModel.compileModel(at:)`. The archive's name supplies the package
    /// name when the payload was archived contents-only.
    @discardableResult
    public static func extract(archiveAt archiveURL: URL, to destination: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)

        // Extract straight into the destination: `aa archive -d DIR` stores
        // DIR's contents at the archive root, so a package archive lands as
        // `Manifest.json` + `Data/…` with no wrapper. The extractor applies
        // stored metadata asynchronously, so we do not rename/move the
        // directory it wrote into — we wrap its *entries* instead.
        guard let file = ArchiveByteStream.fileStream(
                path: FilePath(archiveURL.path), mode: .readOnly,
                options: .init(), permissions: .init(rawValue: 0o644)),
              let decomp = ArchiveByteStream.decompressionStream(readingFrom: file),
              let decode = ArchiveStream.decodeStream(readingFrom: decomp),
              let extract = ArchiveStream.extractStream(extractingTo: FilePath(destination.path)) else {
            throw ArchiveError.extractionFailed("AppleArchive streams unavailable")
        }
        do { _ = try ArchiveStream.process(readingFrom: decode, writingTo: extract) }
        catch { throw ArchiveError.extractionFailed(error.localizedDescription) }
        try? extract.close()
        try rejectSymlinks(under: destination)

        return try normalize(extractedAt: destination, archiveStem: archiveURL.deletingPathExtension().lastPathComponent,
                             destination: destination)
    }

    /// Shape the extracted payload: a discovered `.mlpackage`/`.mlmodel` is
    /// returned as-is; a contents-only payload (no model root inside) gets its
    /// top-level entries wrapped into `<archiveStem>.mlpackage`.
    static func normalize(extractedAt root: URL, archiveStem: String, destination: URL) throws -> URL {
        let fm = FileManager.default

        var found: URL?
        if let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) {
            for case let url as URL in e {
                let name = url.lastPathComponent
                guard name.hasSuffix(".mlpackage") || name.hasSuffix(".mlmodel") else { continue }
                let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
                if name.hasSuffix(".mlmodel") == !isDir { // file .mlmodel, dir .mlpackage
                    found = url
                    break
                }
            }
        }
        if let found { return found }

        let looksLikePackage = fm.fileExists(atPath: root.appendingPathComponent("Data/com.apple.CoreML").path)
            || fm.fileExists(atPath: root.appendingPathComponent("Manifest.json").path)
        guard looksLikePackage else { throw ArchiveError.modelRootNotFound }

        // Contents-only archive of a .mlpackage: wrap the entries.
        let target = destination.appendingPathComponent(archiveStem + ".mlpackage", isDirectory: true)
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        for item in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) {
            if item.standardizedFileURL == target.standardizedFileURL { continue }
            let final = target.appendingPathComponent(item.lastPathComponent)
            if fm.fileExists(atPath: final.path) { try? fm.removeItem(at: final) }
            try fm.moveItem(at: item, to: final)
        }
        return target
    }
}
