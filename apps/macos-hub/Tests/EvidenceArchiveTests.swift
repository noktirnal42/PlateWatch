import AppKit
import CryptoKit
import PlateKit
import PlateSync
import SwiftData
import XCTest

final class EvidenceArchiveTests: XCTestCase {
    private func fixture() throws -> (Data, String) {
        let image = NSImage(size: NSSize(width: 64, height: 40), flipped: false) { rect in
            NSColor.systemBlue.setFill(); rect.fill(); return true
        }
        let bitmap = try XCTUnwrap(NSBitmapImageRep(data: try XCTUnwrap(image.tiffRepresentation)))
        let data = try XCTUnwrap(bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.8]))
        return (data, SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
    }

    func testHashLookupRecoversMissingAndCorruptInlineEvidence() throws {
        let archive = EvidenceArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let (data, hash) = try fixture()
        try archive.store(data, hash: hash)
        XCTAssertEqual(archive.resolve(base64: nil, hash: hash), data)
        XCTAssertEqual(archive.resolve(base64: "broken", hash: hash), data)
        XCTAssertEqual(archive.load(hash: hash.uppercased()), data)
        let attributes = try FileManager.default.attributesOfItem(atPath: archive.directory.appendingPathComponent(hash + ".jpg").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        archive.remove(hash: hash)
        XCTAssertNil(archive.resolve(base64: nil, hash: hash), "A hash cannot reconstruct deleted bytes")
    }

    func testWrongHashInvalidPathAndDamagedBackupAreRefused() throws {
        let archive = EvidenceArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let (data, hash) = try fixture()
        XCTAssertThrowsError(try archive.store(data, hash: String(repeating: "0", count: 64)))
        XCTAssertThrowsError(try archive.store(data, hash: "../outside"))
        XCTAssertNil(archive.load(hash: "../outside"))
        try archive.store(data, hash: hash)
        try Data("damaged".utf8).write(to: archive.directory.appendingPathComponent(hash + ".jpg"))
        XCTAssertNil(archive.load(hash: hash))
        XCTAssertEqual(archive.resolve(base64: data.base64EncodedString(), hash: hash), data)
        try archive.store(data, hash: hash)
        XCTAssertEqual(archive.load(hash: hash), data, "A good inline copy repairs a damaged backup")
    }

    @MainActor func testRejectPreservesSharedBackupUntilLastReferenceIsRemoved() throws {
        let archive = EvidenceArchive(directory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: archive.directory) }
        let (data, hash) = try fixture()
        try archive.store(data, hash: hash)
        let container = try ModelContainer(for: PendingSubmission.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
        let dto = SightingSubmissionDTO(capturedAt: Date(), geohash6: "9q8yyk", cropHashSHA256: hash,
            deviceIDHash: "fixture", fleetConfidence: 0.99, vehicle: .init(vehicleClass: "patrol", classConfidence: 0.99))
        let rows = try (0..<2).map { PendingSubmission(idempotencyKey: "fixture-\($0)", payloadJSON: try JSONEncoder.withISODates.encode(dto)) }
        for row in rows { container.mainContext.insert(row) }
        try container.mainContext.save()
        try ReviewQueue.reject([rows[0].persistentModelID], context: container.mainContext, archive: archive)
        XCTAssertEqual(archive.load(hash: hash), data)
        try ReviewQueue.reject([rows[1].persistentModelID], context: container.mainContext, archive: archive)
        XCTAssertNil(archive.load(hash: hash))
    }
}
