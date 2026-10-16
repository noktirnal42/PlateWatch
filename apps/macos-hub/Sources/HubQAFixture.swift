import AppKit
import FeedIngest
import PlateKit
import PlateSync
import SwiftData

/// Explicit Debug-only QA session. No user queue, camera host, model download,
/// ingest folder, backend or records ledger is mutated by this fixture.
@MainActor
enum HubQAFixture {
    static var enabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("-PWVisualQA")
        #else
        false
        #endif
    }
    static var directory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("PlateWatchVisualQA", isDirectory: true) }

    static func prepare(context: ModelContext) {
        #if DEBUG
        guard enabled else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for index in 1...3 {
            guard let image = drawing(index), let buffer = LiveController.pixelBuffer(from: image) else { continue }
            let vehicle = VehicleObservation(boundingBox: .init(x: 0.1, y: 0.15, width: 0.8, height: 0.7), vehicleClass: .patrol, classConfidence: 0.99)
            // Exercise the owner-reported failure modes in the actual Review UI:
            // overlap previously removed QA-1; neighboring text blacked out QA-2.
            let neighbor = VehicleObservation(
                boundingBox: index == 1 ? .init(x: 0.6, y: 0.3, width: 0.25, height: 0.3)
                    : .init(x: 0.96, y: 0.94, width: 0.03, height: 0.03),
                sceneText: [.init(text: "SYNTHETIC NEIGHBOR", boundingBox: .init(x: 0.36, y: 0.5, width: 0.2, height: 0.1), confidence: 0.99)])
            let crop = EvidenceCrop.make(source: .init(pixelBuffer: buffer), vehicle: vehicle,
                others: index == 3 ? [vehicle] : [vehicle, neighbor])
            let dto = SightingSubmissionDTO(capturedAt: Date().addingTimeInterval(Double(-index * 60)),
                geohash6: "9q8yyk", cropHashSHA256: crop?.sha256Hex, cropJPEGBase64: crop?.base64,
                deviceIDHash: "synthetic-visual-qa", fleetConfidence: 0.99,
                vehicle: .init(vehicle), markings: .init(agencyText: "SYNTHETIC QA FLEET", unitNumber: "QA-\(index)"))
            if let payload = try? JSONEncoder.withISODates.encode(dto) {
                context.insert(PendingSubmission(idempotencyKey: "synthetic-qa-\(index)", payloadJSON: payload))
            }
        }
        try? context.save()
        var sources: [PublicFeedSource] = []
        if let image = drawing(1), let jpeg = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
            try? jpeg.write(to: directory.appendingPathComponent("snapshot.jpg"))
        }
        for (path, kind) in [("snapshot.jpg", PublicFeedSource.Kind.snapshotJPEG), ("stream.m3u8", .hls)] {
            let url = URL(string: "http://127.0.0.1:8768/\(path)")!
            if let source = try? PublicFeedSource(name: "Synthetic QA \(kind == .hls ? "HLS video" : "snapshot")", url: url, kind: kind,
                refreshInterval: 5, geohash6: "9q8yyk", citation: .init(sourceType: .openDataPortal, url: url),
                state: "CA", terms: .init(licenseClass: .publicDomain, termsURL: url, termsReadOn: Date(), automatedUseAllowed: true)) {
                sources.append(source)
            }
        }
        try? FeedCatalogue(sources: sources).write(to: directory.appendingPathComponent("feeds.json"))
        #endif
    }

    private static func drawing(_ index: Int) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: 640, height: 360, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 0.18, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        ctx.setFillColor(CGColor(red: 0.2, green: 0.45 + Double(index) * 0.1, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 90, y: 90, width: 460, height: 120)); ctx.fill(CGRect(x: 190, y: 210, width: 240, height: 70))
        ctx.setFillColor(CGColor(gray: 0.06, alpha: 1))
        for x in [150, 440] { ctx.fillEllipse(in: CGRect(x: x, y: 60, width: 65, height: 65)) }
        ctx.setFillColor(CGColor(gray: 0.95, alpha: 1)); ctx.fill(CGRect(x: 230, y: 125, width: 170, height: 45))
        return ctx.makeImage()
    }
}
