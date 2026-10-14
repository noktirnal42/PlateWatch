import AppleArchive
@testable import VehicleML
import XCTest

final class ModelArchiveTests: XCTestCase {
    /// Skip gracefully where the `aa` CLI is unavailable (non-macOS CI).
    private var aaAvailable: Bool { FileManager.default.fileExists(atPath: "/usr/bin/aa") }

    @discardableResult
    private func archive(_ source: URL, to aar: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/aa")
        process.arguments = ["archive", "-d", source.path, "-o", aar.path]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, "aa archive failed")
    }

    func testExtractContentsOnlyPackage() throws {
        // A .mlpackage archived with `aa archive -d pkg` stores its contents at
        // the root — ModelArchive must reassemble the named package.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let pkg = work.appendingPathComponent("test-model.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("Data/com.apple.CoreML/weights"),
                                                withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: pkg.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin"))
        try Data("{}" .utf8).write(to: pkg.appendingPathComponent("Manifest.json"))

        let aar = work.appendingPathComponent("test-model.aar")
        guard aaAvailable else { throw XCTSkip("aa CLI unavailable") }
        try archive(pkg, to: aar)

        let out = work.appendingPathComponent("out", isDirectory: true)
        let root = try ModelArchive.extract(archiveAt: aar, to: out)
        XCTAssertEqual(root.lastPathComponent, "test-model.mlpackage")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Manifest.json").path))
        // Scratch must be gone.
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: out.path).count == 1)
    }

    func testExtractArchiveWithNamedModelFile() throws {
        // A root-level .mlmodel inside the archive is moved out unchanged.
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let wrap = work.appendingPathComponent("wrap", isDirectory: true)
        try FileManager.default.createDirectory(at: wrap, withIntermediateDirectories: true)
        try Data("coreml".utf8).write(to: wrap.appendingPathComponent("tiny.mlmodel"))

        let aar = work.appendingPathComponent("tiny.aar")
        guard aaAvailable else { throw XCTSkip("aa CLI unavailable") }
        try archive(wrap, to: aar)

        let out = work.appendingPathComponent("out", isDirectory: true)
        let root = try ModelArchive.extract(archiveAt: aar, to: out)
        XCTAssertEqual(root.lastPathComponent, "tiny.mlmodel")
        XCTAssertEqual(try Data(contentsOf: root), Data("coreml".utf8))
    }

    func testSymlinkEntryIsRejectedAndCleanedUp() throws {
        guard aaAvailable else { throw XCTSkip("aa CLI unavailable") }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-\(UUID().uuidString)", isDirectory: true)
        let wrap = work.appendingPathComponent("wrap", isDirectory: true)
        try FileManager.default.createDirectory(at: wrap, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data("x".utf8).write(to: wrap.appendingPathComponent("tiny.mlmodel"))
        try FileManager.default.createSymbolicLink(atPath: wrap.appendingPathComponent("evil").path, withDestinationPath: "/etc")
        let aar = work.appendingPathComponent("evil.aar")
        try archive(wrap, to: aar)

        let scratch = work.appendingPathComponent("scratch", isDirectory: true)
        XCTAssertThrowsError(try ModelArchive.extractIsolated(archiveAt: aar, workDirectory: scratch))
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.path), "work directory must be removed on failure")
    }

    func testExtractIsolatedReturnsModelInsidePayload() throws {
        guard aaAvailable else { throw XCTSkip("aa CLI unavailable") }
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("ma-\(UUID().uuidString)", isDirectory: true)
        let wrap = work.appendingPathComponent("wrap", isDirectory: true)
        try FileManager.default.createDirectory(at: wrap, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        try Data("coreml".utf8).write(to: wrap.appendingPathComponent("ok.mlmodel"))
        let aar = work.appendingPathComponent("ok.aar")
        try archive(wrap, to: aar)
        let scratch = work.appendingPathComponent("scratch", isDirectory: true)
        let root = try ModelArchive.extractIsolated(archiveAt: aar, workDirectory: scratch)
        XCTAssertTrue(root.path.contains("/payload/"))
        XCTAssertEqual(root.lastPathComponent, "ok.mlmodel")
    }
}
