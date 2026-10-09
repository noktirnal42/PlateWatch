import AVFoundation
import CaptureKit
import CoreLocation
import Foundation
import PlateKit
import PlateSync
import SwiftData
import SwiftUI
import VehicleML

/// Wires CaptureKit → VehicleML → RedactionGate → PlateSync outbox.
/// MainActor-isolated for UI; analysis runs off-actor via the executor.
@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var latestFrame: DetectionFrame?
    @Published private(set) var statusText = "idle"
    @Published var fleetHitPending = false
    @Published var permissionDenied = false

    private let session: PlateCaptureSession
    private let executor: AnalysisExecutor
    private let gate = RedactionGate(config: .standard)
    private let modelManager: ModelManager
    private var modelContext: ModelContext?
    private var backend: (any SyncBackend)?

    var captureSession: AVCaptureSession { session.previewSession }

    nonisolated private static func makeModelManager() -> ModelManager {
        let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                               in: .userDomainMask).first!
            .appending(path: "PlateWatch/Models", directoryHint: .isDirectory)
        let registryURL = URL(string: "https://raw.githubusercontent.com/noktirnal42/PlateWatch/main/models/registry.json")!
        return ModelManager(config: .init(registryURL: registryURL, cacheDirectory: support))
    }

    init() {
        let manager = Self.makeModelManager()
        self.modelManager = manager
        self.session = PlateCaptureSession(configuration: .dashcam)
        // Context provider probes the manager each run — models hot-swap in
        // as downloads complete.
        let pipeline = PlateAnalysisPipeline()
        self.executor = AnalysisExecutor(pipeline: pipeline) {
            // Models are opt-in upgrades; absence means baseline Vision only.
            AnalysisContext(models: [:])
        }
        session.onFrame { [weak self] packet in
            Task { [weak self] in await self?.handle(packet) }
        }
    }

    func attach(context: ModelContext, backend: any SyncBackend) {
        self.modelContext = context
        self.backend = backend
    }

    func start() async {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            permissionDenied = !(await AVCaptureDevice.requestAccess(for: .video))
            guard !permissionDenied else { return }
        default:
            permissionDenied = true
            return
        }
        do {
            try session.configure()
            session.start()
            statusText = "scanning"
        } catch {
            statusText = "camera error"
        }
    }

    func stop() {
        session.stop()
        statusText = "idle"
    }

    private func handle(_ packet: FramePacket) async {
        guard let frame = try? await executor.submit(
            .init(pixelBuffer: packet.pixelBuffer), mode: .live) else { return }
        latestFrame = frame

        var confidences: [UUID: Double] = [:]
        var approved: [(VehicleObservation, Double)] = []
        for vehicle in frame.vehicles {
            let markings = SceneTextHeuristics.parse(vehicle.sceneText)
            let confidence = gate.fleetConfidence(
                vehicleClassifierFleet: vehicle.vehicleClass.isFleet ? vehicle.classConfidence : 0,
                hasFleetMarkings: markings.hasFleetKeyword,
                knownUnitMatch: false,   // roster cache lookup lands in M3
                exemptPlateDesign: vehicle.plates.contains { $0.best?.exemptDesignHint == true })
            confidences[vehicle.id] = confidence
            if gate.verdict(fleetConfidence: confidence) == .persistAndSync {
                approved.append((vehicle, confidence))
            }
        }
        fleetHitPending = !approved.isEmpty
        statusText = approved.isEmpty ? "scanning" : "fleet vehicle — queued"

        // Persist through the outbox; the drainer owns retries.
        guard let modelContext else { return }
        for (vehicle, confidence) in approved {
            let dto = SightingSubmissionDTO(
                capturedAt: frame.timestamp,
                geohash6: LocationBucketer.currentGeohash6() ?? "",
                deviceIDHash: (try? DeviceIdentity.loadOrCreate().publicKeyHash) ?? "unknown",
                fleetConfidence: confidence,
                plate: vehicle.plates.first?.best.map(PlateDTO.init),
                vehicle: VehicleObservationDTO(vehicle),
                markings: FleetMarkingsDTO(SceneTextHeuristics.parse(vehicle.sceneText)))
            guard let payload = try? JSONEncoder.withISODates.encode(dto) else { continue }
            let key = OutboxDrainer.idempotencyKey(for: dto)
            modelContext.insert(PendingSubmission(idempotencyKey: key, payloadJSON: payload))
        }
        try? modelContext.save()
        // Draining policy: the app drains on scene activation + a repeating
        // timer (Task in PlateWatchApp), not per-frame — a dead zone must
        // never stall the capture loop on network.
    }
}

/// ~1 km geo bucket helper. Exact coords are attached later, only for
/// fleet-confirmed sightings, per LEGAL-ETHICS.
enum LocationBucketer {
    static func currentGeohash6() -> String? {
        // CoreLocation hook lands with entitlements; geohash-6 is computed
        // from the last known location to avoid continuous GPS.
        nil  // placeholder until CLLocationManager integration (M1)
    }
}
