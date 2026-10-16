import AppKit
import PlateKit
import PlateSync
import SwiftData
import SwiftUI
import XCTest

final class ReviewQueueTests: XCTestCase {
    @MainActor func testBulkRejectionOnlyDeletesSelectedRows() throws {
        let container = try ModelContainer(for: PendingSubmission.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let context = container.mainContext
        let rows = (0..<3).map { PendingSubmission(idempotencyKey: "synthetic-\($0)", payloadJSON: Data()) }
        for row in rows { context.insert(row) }
        try context.save()
        XCTAssertEqual(try ReviewQueue.reject([rows[0].persistentModelID, rows[2].persistentModelID], context: context), 2)
        let remaining = try context.fetch(FetchDescriptor<PendingSubmission>())
        XCTAssertEqual(remaining.map(\.idempotencyKey), ["synthetic-1"])
    }

    /// Offscreen rendering of the actual Review view; no desktop UI input or
    /// screen capture, and no access to the operator's persistent queue.
    @MainActor func testRenderSyntheticReviewArtifact() async throws {
        guard let folder = ProcessInfo.processInfo.environment["PLATEWATCH_QA_ARTIFACTS"] else { throw XCTSkip("Opt-in offscreen render artifact") }
        let directory = URL(fileURLWithPath: folder)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let container = try ModelContainer(for: PendingSubmission.self, configurations: ModelConfiguration(isStoredInMemoryOnly: true))
        let ctx = try XCTUnwrap(CGContext(data: nil, width: 320, height: 180, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 320, height: 180))
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: try XCTUnwrap(ctx.makeImage())).representation(using: .jpeg, properties: [:]))
        for index in 1...3 {
            let dto = SightingSubmissionDTO(capturedAt: Date(), geohash6: "9q8yyk", cropJPEGBase64: jpeg.base64EncodedString(),
                deviceIDHash: "synthetic-qa", fleetConfidence: 0.99,
                vehicle: .init(vehicleClass: "patrol", classConfidence: 0.99), markings: .init(agencyText: "SYNTHETIC QA FLEET", unitNumber: "QA-\(index)"))
            container.mainContext.insert(PendingSubmission(idempotencyKey: "synthetic-qa-\(index)", payloadJSON: try JSONEncoder.withISODates.encode(dto)))
        }
        try container.mainContext.save()
        let root = ReviewPane().modelContainer(container).frame(width: 1180, height: 650)
            .background(Color(nsColor: .windowBackgroundColor))
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1180, height: 650), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(for: .milliseconds(300))
        host.displayIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: directory.appendingPathComponent("review-offscreen.png"))
        XCTAssertGreaterThan(png.count, 1000)
        window.close()
    }
}
