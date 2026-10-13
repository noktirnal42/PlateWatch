import AVFoundation
import CaptureKit
import CoreLocation
import CoreML
import Foundation
import PlateKit
import PlateSync
import SwiftData
import SwiftUI
import VehicleML

/// What a manual still / imported photo produced. Drives the results sheet.
struct CaptureResult: Identifiable {
    let id = UUID()
    var source: String            // "still" | "photo" | "live"
    var plates: [String]          // best reads
    var fleetCount: Int
    var vehicleCount: Int
    var watchlistHits: Int
    var topFleetConfidence: Double
    var error: String?

    static func failed(_ source: String, _ message: String) -> CaptureResult {
        CaptureResult(source: source, plates: [], fleetCount: 0, vehicleCount: 0,
                      watchlistHits: 0, topFleetConfidence: 0, error: message)
    }
}

/// Wires CaptureKit → VehicleML → RedactionGate → PlateSync outbox.
/// MainActor-isolated for UI; analysis runs off-actor via the executor.
@MainActor
final class CaptureViewModel: ObservableObject {
    @Published private(set) var latestFrame: DetectionFrame?
    @Published private(set) var statusText = "idle"
    @Published var fleetHitPending = false
    @Published var permissionDenied = false
    @Published private(set) var latestEventClip: EventClip?
    @Published private(set) var modelStatus = "baseline vision"
    @Published var lastResult: CaptureResult?
    @Published private(set) var processingStill = false

    private let session: PlateCaptureSession
    private let executor: AnalysisExecutor
    private let gate = RedactionGate(config: .standard)
    private let modelManager: ModelManager
    private var modelContext: ModelContext?
    private var backend: (any SyncBackend)?
    private let contextBox = AnalysisContextBox()
    private var lastPacket: FramePacket?

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
        // Context provider reads the live box — CoreML models hot-swap in
        // as downloads complete; absence means baseline Vision only.
        let box = contextBox
        let pipeline = PlateAnalysisPipeline()
        self.executor = AnalysisExecutor(pipeline: pipeline) { box.current }
        session.onFrame { [weak self] packet in
            Task { [weak self] in await self?.handle(packet) }
        }
        session.onFleetEvent { [weak self] clip in
            Task { @MainActor [weak self] in self?.latestEventClip = clip }
        }
    }

    /// Pull the registry and install any detector models for this session.
    /// Best-effort: failures leave baseline Vision active, never crash.
    /// MLModel instances stay inside the detached task / context box — they
    /// are thread-safe but not Sendable, so they never cross back here.
    func refreshModels() async {
        let box = contextBox
        let manager = modelManager
        let count: Int = await Task.detached(priority: .utility) {
            do {
                let registry = try await manager.fetchRegistry()
                var models: [String: MLModel] = [:]
                for task in ["vehicle-detection", "plate-detection"] {
                    if let compiled = try? await manager.model(forTask: task, registry: registry) {
                        models[task] = compiled.mlModel
                    }
                }
                box.current = AnalysisContext(models: models)
                return models.count
            } catch {
                return 0
            }
        }.value
        modelStatus = count == 0 ? "baseline vision" : "CoreML active (\(count) models)"
    }

    func attach(context: ModelContext, backend: any SyncBackend) {
        self.modelContext = context
        self.backend = backend
    }

    func start() async {
        // Models are opt-in upgrades; try to install detectors before the
        // first frame, and never block capture on the network result.
        Task { await refreshModels() }
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
            // Surface the real cause — "camera error" alone is unactionable.
            statusText = "camera error: \(error.localizedDescription)"
        }
    }

    func stop() {
        session.stop()
        statusText = "idle"
    }

    // MARK: - Manual capture paths

    /// Shutter button: run one accurate pass on the freshest live frame.
    /// Uses `.processAll` so a busy loop can't drop the request.
    func captureStill() async {
        guard let packet = lastPacket else {
            lastResult = .failed("still", "No frame buffered yet — wait for the preview to start.")
            return
        }
        await runAccurate(pixelBuffer: packet.pixelBuffer, source: "still")
    }

    /// Photo-library import: the deterministic way to test detection (point
    /// the picker at a police-vehicle photo and read what the pipeline saw).
    func processPhoto(_ data: Data) async {
        guard let buffer = FileFrameSource.pixelBuffer(from: data) else {
            lastResult = .failed("photo", "Could not decode that image.")
            return
        }
        await runAccurate(pixelBuffer: buffer, source: "photo")
    }

    private func runAccurate(pixelBuffer: CVPixelBuffer, source: String) async {
        processingStill = true
        defer { processingStill = false }
        statusText = "processing \(source)…"
        guard let frame = try? await executor.submit(
            FramePacketLike(pixelBuffer: pixelBuffer), mode: .processAll) else {
            statusText = "analysis failed"
            lastResult = .failed(source, "The analyzer could not process this frame.")
            return
        }
        latestFrame = frame
        let result = await evaluateAndPersist(frame: frame, source: source)
        lastResult = result
        if result.fleetCount > 0 {
            statusText = result.watchlistHits > 0
                ? "watchlist hit · \(result.watchlistHits)"
                : "fleet vehicle — queued"
        } else {
            statusText = result.plates.isEmpty ? "\(source) · no plates read" : "\(source) · queued"
        }
        PassiveCaptureStatus.shared.set(statusText: statusText,
                                        fleetHit: result.fleetCount > 0,
                                        modelStatus: modelStatus)
    }

    /// Gate + persist + watchlist for any analyzed frame (live or manual).
    private func evaluateAndPersist(frame: DetectionFrame, source: String) async -> CaptureResult {
        var approved: [(VehicleObservation, Double)] = []
        var bestConfidence = 0.0
        for vehicle in frame.vehicles {
            let markings = await parseMarkings(vehicle.sceneText)
            let confidence = gate.fleetConfidence(
                vehicleClassifierFleet: vehicle.vehicleClass.isFleet ? vehicle.classConfidence : 0,
                hasFleetMarkings: markings.hasFleetKeyword,
                knownUnitMatch: false,
                exemptPlateDesign: vehicle.plates.contains { $0.best?.exemptDesignHint == true })
            bestConfidence = max(bestConfidence, confidence)
            if gate.verdict(fleetConfidence: confidence) == .persistAndSync {
                approved.append((vehicle, confidence))
            }
        }
        fleetHitPending = !approved.isEmpty

        // Persist through the outbox; the drainer owns retries.
        var watchlistHits = 0
        if let modelContext {
            let bucket = LocationProvider.shared.currentBucket()
            for (vehicle, confidence) in approved {
                let dto = SightingSubmissionDTO(
                    capturedAt: frame.timestamp,
                    geohash6: bucket?.geohash6 ?? "",
                    exactLatitude: nil,  // exact geo attaches post-confirmation
                    exactLongitude: nil,
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

            if !approved.isEmpty {
                let items = (try? modelContext.fetch(FetchDescriptor<WatchlistItem>())) ?? []
                watchlistHits = WatchlistEvaluator.evaluate(frame, items: items).count
            }
        }

        let plates = frame.vehicles
            .compactMap { $0.plates.first?.best }
            .sorted { $0.confidence > $1.confidence }
            .map { "\($0.text) (\(Int($0.confidence * 100))%)" }
        return CaptureResult(source: source,
                             plates: plates,
                             fleetCount: approved.count,
                             vehicleCount: frame.vehicles.count,
                             watchlistHits: watchlistHits,
                             topFleetConfidence: bestConfidence,
                             error: nil)
    }

    private func handle(_ packet: FramePacket) async {
        lastPacket = packet
        guard let frame = try? await executor.submit(
            .init(pixelBuffer: packet.pixelBuffer), mode: .live) else { return }
        latestFrame = frame

        let result = await evaluateAndPersist(frame: frame, source: "live")
        if processingStill {
            return // a manual pass owns the status line right now
        }
        if result.fleetCount > 0 {
            statusText = result.watchlistHits > 0
                ? "watchlist hit · \(result.watchlistHits)"
                : "fleet vehicle — queued"
            // Rolling-buffer event clip around the trigger frame.
            if let clip = session.extractEventClip(triggerFrameIndex: Int(packet.sequenceNumber)) {
                latestEventClip = clip
            }
        } else {
            statusText = "scanning"
        }
        PassiveCaptureStatus.shared.set(statusText: statusText,
                                        fleetHit: result.fleetCount > 0,
                                        modelStatus: modelStatus)
    }

    /// LLM-first markings parse with deterministic fallback. FleetMarkings
    /// LLM runs on-device (Apple Intelligence); pre-iOS 26 falls back to the
    /// regex heuristics without a network round-trip either.
    private func parseMarkings(_ observations: [SceneTextObservation]) async -> FleetMarkings {
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let lines = observations.map(\.text)
            if let parsed = await FleetMarkingsLLMParser.parse(lines) {
                return parsed
            }
        }
        #endif
        return SceneTextHeuristics.parse(observations)
    }
}

/// Thread-safe holder for the live AnalysisContext. The executor's
/// synchronous provider reads this; the async model installer writes it.
final class AnalysisContextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _current = AnalysisContext(models: [:])

    var current: AnalysisContext {
        get { lock.lock(); defer { lock.unlock() }; return _current }
        set { lock.lock(); defer { lock.unlock() }; _current = newValue }
    }
}
