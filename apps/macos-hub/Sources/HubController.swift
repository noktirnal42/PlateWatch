import CaptureKit
import PlateSync
import Foundation
import PlateKit
import SwiftData
import VehicleML

/// Fixed-camera ingest. v1 watches a folder that IP cameras FTP snapshots
/// into (every Reolink/Amcrest-class camera supports this) — zero SDKs, no
/// cloud accounts, cameras never touch the internet, which is on-mission.
/// RTSP ingest is roadmap M1 (see docs/ROADMAP.md).
@MainActor
final class HubController: ObservableObject {
    @Published private(set) var ingestFolder: URL
    @Published private(set) var framesAnalyzed = 0
    @Published private(set) var fleetHitsToday = 0
    @Published private(set) var pendingCount = 0

    private let pipeline = PlateAnalysisPipeline()
    private let fileSource = FileFrameSource()
    private let gate = RedactionGate(config: .standard)
    private var watchDescriptor: DispatchSourceFileSystemObject?

    private var modelContext: ModelContext?
    /// Hub operator-set location bucket (these are fixed installations —
    /// the geohash-6 of the camera's own location).
    var homeGeohash6 = ""

    init() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.ingestFolder = docs.appending(path: "PlateWatch-Ingest", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: ingestFolder, withIntermediateDirectories: true)
        startWatching()
    }

    func attach(context: ModelContext) {
        self.modelContext = context
    }

    func chooseIngestFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        if panel.runModal() == .OK, let url = panel.url {
            ingestFolder = url
            startWatching()
        }
    }

    private func startWatching() {
        watchDescriptor?.cancel()
        let fd = open(ingestFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in
            Task { @MainActor in self?.processNewFiles() }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watchDescriptor = source
    }

    private func processNewFiles() {
        let fm = FileManager.default
        guard let all = try? fm.contentsOfDirectory(
            at: ingestFolder, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return }
        let images = all.filter { ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) }

        Task {
            for url in images {
                guard let buffer = FileFrameSource.pixelBuffer(from: url) else { continue }
                let frame = try? await pipeline.analyze(
                    .init(pixelBuffer: buffer),
                    context: AnalysisContext(models: [:]))
                filesProcessed += 1
                framesAnalyzed = filesProcessed
                guard let frame else {
                    try? fm.removeItem(at: url) // undecodable input, discard
                    continue
                }

                for vehicle in frame.vehicles {
                    let markings = SceneTextHeuristics.parse(vehicle.sceneText)
                    let confidence = gate.fleetConfidence(
                        vehicleClassifierFleet: vehicle.vehicleClass.isFleet ? vehicle.classConfidence : 0,
                        hasFleetMarkings: markings.hasFleetKeyword,
                        knownUnitMatch: false,
                        exemptPlateDesign: vehicle.plates.contains { $0.best?.exemptDesignHint == true })
                    if gate.verdict(fleetConfidence: confidence) == .persistAndSync {
                        fleetHitsToday += 1
                        if let context = modelContext {
                            let dto = SightingSubmissionDTO(
                                capturedAt: frame.timestamp,
                                geohash6: homeGeohash6,
                                deviceIDHash: (try? DeviceIdentity.loadOrCreate().publicKeyHash) ?? "unknown",
                                fleetConfidence: confidence,
                                plate: vehicle.plates.first?.best.map(PlateDTO.init),
                                vehicle: VehicleObservationDTO(vehicle),
                                markings: FleetMarkingsDTO(markings))
                            if let payload = try? JSONEncoder.withISODates.encode(dto) {
                                context.insert(PendingSubmission(
                                    idempotencyKey: OutboxDrainer.idempotencyKey(for: dto),
                                    payloadJSON: payload))
                                try? context.save()
                                pendingCount += 1
                            }
                        }
                    }
                }
                // Rolling source media: hub keeps only fleet-hit crops,
                // never the raw camera flow (LEGAL-ETHICS).
                try? fm.removeItem(at: url)
            }
        }
    }

    private var filesProcessed = 0
}

import AppKit
import Darwin
