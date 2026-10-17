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

/// A detection with real fleet evidence that did not clear the automatic
/// gate. The user can confirm it; it then enters the server's moderation
/// queue (never public on the user's say-so alone).
struct ReviewCandidate: Identifiable {
    let id = UUID()
    var submission: SightingSubmissionDTO
    var summary: String
    var confidence: Double
    var identity: VehicleIdentity?
    /// Kept so the identity can be re-resolved when a reviewer settles an ambiguous place.
    var vehicle: VehicleObservation
    var markings: FleetMarkings
    var confirmed = false
}

/// What a manual still / imported photo produced. Drives the results sheet.
struct CaptureResult: Identifiable {
    let id = UUID()
    var source: String            // "still" | "photo" | "live"
    var plates: [String]          // best reads
    var fleetCount: Int
    var vehicleCount: Int
    var watchlistHits: Int
    var topFleetConfidence: Double
    var approvalThreshold: Double = 0.55
    var markings: [String] = []   // human-readable: "Service: POLICE", "Unit: 4421"…
    var candidates: [ReviewCandidate] = []  // plausible fleet vehicles below the auto-record bar
    /// Everything read off the best vehicle, structured for cross-referencing
    /// (agency, plate jurisdiction, unit, make/model) with its evidence.
    var identity: VehicleIdentity?
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
    /// What the camera is doing, in words a person can act on.
    enum CameraState: Equatable {
        case starting, running, denied
        case unavailable(String)
    }

    @Published private(set) var cameraState = CameraState.starting
    @Published private(set) var statusText = "Starting camera…"
    /// A running AVCaptureSession can still be waiting for its first sample
    /// buffer (for example while a physical lens is waking). Keep that state
    /// explicit so the UI never claims that analysis is active prematurely.
    @Published private(set) var hasReceivedFrame = false
    @Published var fleetHitPending = false
    @Published var permissionDenied = false
    @Published private(set) var latestEventClip: EventClip?
    @Published private(set) var exportedEventClipURL: URL?
    @Published private(set) var modelStatus = "baseline vision"
    @Published var lastResult: CaptureResult?
    @Published private(set) var processingStill = false

    private let session: PlateCaptureSession
    private let executor: AnalysisExecutor
    private let gate = RedactionGate(config: .standard)
    private let identityResolver = IdentityResolver()
    private let modelManager: ModelManager
    private var modelContext: ModelContext?
    private var backend: (any SyncBackend)?
    private let contextBox = AnalysisContextBox()
    /// Plate recognition is off wherever it is regulated (PlateKit.JurisdictionPolicy) and when the location is unknown.
    private let plateGate = PlateReadingGate()
    private var lastPacket: FramePacket?
    private var lastEscalation = Date.distantPast
    private var escalating = false

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
        let plateGate = plateGate
        self.executor = AnalysisExecutor(pipeline: pipeline) {
            var context = box.current
            context.readPlates = plateGate.allowed
            return context
        }
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
        // Shared with the Hub; a developer-override model in <cache>/Local/<task>.mlmodel loads even offline.
        let count: Int = await Task.detached(priority: .utility) {
            await manager.install(tasks: ["vehicle-detection", "plate-detection"], into: box)
        }.value
        modelStatus = count == 0 ? "baseline vision" : "CoreML active (\(count) models)"
    }

    func attach(context: ModelContext, backend: any SyncBackend) {
        self.modelContext = context
        self.backend = backend
    }

    /// Encodes the current bounded event buffer off the main actor and returns
    /// a local movie suitable for an explicit Share action.
    func exportLatestEventClip() async -> URL? {
        guard let clip = latestEventClip else { return nil }
        let url = FileManager.default.temporaryDirectory
            .appending(path: "PlateWatch-event-\(UUID().uuidString).mp4")
        do {
            try await Task.detached(priority: .utility) {
                try EventClipExporter.export(clip, to: url)
            }.value
            exportedEventClipURL = url
            return url
        } catch {
            statusText = "Event clip export failed: \(error.localizedDescription)"
            return nil
        }
    }

    func start() async {
        hasReceivedFrame = false
        // Models are opt-in upgrades; try to install detectors before the
        // first frame, and never block capture on the network result.
        Task { await refreshModels() }
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: break
        case .notDetermined:
            permissionDenied = !(await AVCaptureDevice.requestAccess(for: .video))
            guard !permissionDenied else { cameraState = .denied; statusText = "Camera access is off"; return }
        default:
            permissionDenied = true
            cameraState = .denied
            statusText = "Camera access is off"
            return
        }
        do {
            try session.configure()
            session.start()
            PresenceCoordinator.shared.start()
            cameraState = .running
            statusText = "Scanning for fleet vehicles"
        } catch {
            let message = error.localizedDescription
            cameraState = .unavailable(message)
            statusText = "No live camera — import a photo to analyze"
        }
    }

    func stop() {
        session.stop()
        PresenceCoordinator.shared.stop()
        if cameraState == .running { statusText = "Paused" }
    }

    // MARK: - Manual capture paths

    /// Shutter button: run one accurate pass on the freshest live frame.
    /// Uses `.processAll` so a busy loop can't drop the request.
    func captureStill() async {
        guard let packet = lastPacket else {
            switch cameraState {
            case .running, .starting:
                lastResult = .failed("still", "The camera is still warming up. Try again in a moment.")
            case .denied:
                lastResult = .failed("still", "Camera access is off. Turn it on in Settings, or import a photo instead.")
            case .unavailable:
                lastResult = .failed("still", "There is no live camera on this device. Use the photo button to import a picture to analyze.")
            }
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
        // An imported photo says where *it* was taken. The phone's current location is wrong for an
        // old photo, so a photo without GPS gets no location at all (never the phone's).
        importedPhoto = (isImport: true, gps: ImageLocation.coordinate(in: data))
        defer { importedPhoto = (isImport: false, gps: nil) }
        await runAccurate(pixelBuffer: buffer, source: "photo")
    }

    private var importedPhoto: (isImport: Bool, gps: (latitude: Double, longitude: Double)?) = (false, nil)

    /// Where the frame being analysed was captured: the photo's own GPS for an import, otherwise the
    /// phone's current ~1 km bucket (live capture).
    private func captureLocation() -> (geohash6: String, latitude: Double, longitude: Double)? {
        if importedPhoto.isImport {
            guard let gps = importedPhoto.gps else { return nil }
            return (Geohash.encode(latitude: gps.latitude, longitude: gps.longitude, precision: 6),
                    gps.latitude, gps.longitude)
        }
        guard let bucket = LocationProvider.shared.currentBucket(),
              let center = Geohash.decodeCenter(bucket.geohash6) else { return nil }
        return (bucket.geohash6, center.latitude, center.longitude)
    }

    /// Re-evaluates whether plates may be read at the location the frame being analysed was captured.
    private func refreshPlateGate() {
        let location = captureLocation()
        plateGate.update(latitude: location?.latitude, longitude: location?.longitude)
    }

    private func runAccurate(pixelBuffer: CVPixelBuffer, source: String) async {
        processingStill = true
        refreshPlateGate()
        defer { processingStill = false }
        statusText = source == "photo" ? "Analyzing photo…" : "Analyzing frame…"
        guard let frame = try? await executor.submit(
            FramePacketLike(pixelBuffer: pixelBuffer), mode: .processAll) else {
            statusText = "Could not analyze that image"
            lastResult = .failed(source, "The analyzer could not process this frame.")
            return
        }
        if source == "still" { latestFrame = frame } // photo coordinates don't match the live preview
        let result = await evaluateAndPersist(frame: frame, source: source)
        lastResult = result
        if result.fleetCount > 0 {
            statusText = result.watchlistHits > 0
                ? "Watchlist hit · \(result.watchlistHits)"
                : "Fleet vehicle recorded"
        } else {
            statusText = result.plates.isEmpty ? "No fleet vehicle found" : "Plate read — not fleet-confirmed"
        }
        PassiveCaptureStatus.shared.set(statusText: statusText,
                                        fleetHit: result.fleetCount > 0,
                                        modelStatus: modelStatus)
    }

    /// Gate + persist + watchlist for any analyzed frame (live or manual).
    private func evaluateAndPersist(frame: DetectionFrame, source: String) async -> CaptureResult {
        var approved: [(VehicleObservation, Double, FleetMarkings)] = []
        var review: [(VehicleObservation, Double, FleetMarkings)] = []
        var bestConfidence = 0.0
        var bestMarkings = FleetMarkings()
        var best: (VehicleObservation, Double, FleetMarkings)?
        for vehicle in frame.vehicles {
            let parsed = await parseMarkings(vehicle.sceneText)
            // One scoring entry point for every caller (PlateKit.FleetScoring).
            let (confidence, markings) = FleetScoring.vehicleGateScore(gate: gate, vehicle: vehicle, markings: parsed)
            if confidence >= bestConfidence { bestConfidence = confidence; bestMarkings = markings; best = (vehicle, confidence, markings) }
            switch gate.verdict(fleetConfidence: confidence) {
            case .persistAndSync:
                approved.append((vehicle, confidence, markings))
            case .keepLocalOnly:
                // Real evidence (fleet text, or a fleet-class cue) but not
                // enough to record unattended: offer it for confirmation.
                if markings.hasFleetKeyword || (vehicle.vehicleClass.isFleet && vehicle.classConfidence > 0) {
                    review.append((vehicle, confidence, markings))
                }
            case .discard: break
            }
        }
        fleetHitPending = !approved.isEmpty

        // Persist through the outbox; the drainer owns retries.
        var watchlistHits = 0
        if let modelContext {
            for (vehicle, confidence, markings) in approved {
                enqueue(makeSubmission(frame: frame, vehicle: vehicle, confidence: confidence, markings: markings),
                        in: modelContext)
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
        let candidates = approved.isEmpty ? review.map { vehicle, confidence, markings in
            ReviewCandidate(
                submission: makeSubmission(frame: frame, vehicle: vehicle, confidence: confidence, markings: markings),
                summary: resolveIdentity(vehicle: vehicle, markings: markings).agency?.name
                    ?? Self.describe(markings).joined(separator: " · ").nonEmpty
                    ?? "\(vehicle.vehicleClass.rawValue.capitalized)-shaped vehicle",
                confidence: confidence,
                identity: resolveIdentity(vehicle: vehicle, markings: markings),
                vehicle: vehicle, markings: markings)
        } : []
        return CaptureResult(source: source,
                             plates: plates,
                             fleetCount: approved.count,
                             vehicleCount: frame.vehicles.count,
                             watchlistHits: watchlistHits,
                             topFleetConfidence: bestConfidence,
                             approvalThreshold: gate.config.persistThreshold,
                             markings: Self.describe(bestMarkings),
                             candidates: candidates,
                             identity: best.map { resolveIdentity(vehicle: $0.0, markings: $0.2) },
                             error: nil)
    }

    private func makeSubmission(frame: DetectionFrame, vehicle: VehicleObservation,
                                confidence: Double, markings: FleetMarkings) -> SightingSubmissionDTO {
        return SightingSubmissionDTO(
            capturedAt: frame.timestamp,
            geohash6: captureLocation()?.geohash6 ?? "",
            exactLatitude: nil,  // exact geo attaches post-confirmation
            exactLongitude: nil,
            deviceIDHash: (try? DeviceIdentity.loadOrCreate().publicKeyHash) ?? "unknown",
            fleetConfidence: confidence,
            plate: vehicle.plates.first?.best.map(PlateDTO.init),
            vehicle: VehicleObservationDTO(vehicle),
            markings: FleetMarkingsDTO(markings),
            identity: syncIdentity(vehicle: vehicle, confidence: confidence, markings: markings))
    }

    /// The structured identity for this vehicle, using the phone's coarse location (the same ~1 km
    /// bucket sightings already use) only to settle ambiguous place names.
    private func resolveIdentity(vehicle: VehicleObservation, markings: FleetMarkings) -> VehicleIdentity {
        let hint = captureLocation().map { IdentityResolver.LocationHint(latitude: $0.latitude, longitude: $0.longitude) }
        return identityResolver.resolve(sceneText: vehicle.sceneText, plates: vehicle.plates,
                                        vehicleClass: vehicle.vehicleClass, markings: markings,
                                        location: hint, enhancedText: vehicle.enhancedText)
    }

    /// Identity as it may leave the device: the registration is stripped unless the sighting is
    /// allowed to carry a plate (fleet-confirmed), exactly like `plate`.
    private func syncIdentity(vehicle: VehicleObservation, confidence: Double, markings: FleetMarkings) -> VehicleIdentity? {
        let identity = resolveIdentity(vehicle: vehicle, markings: markings)
        guard !identity.isEmpty else { return nil }
        return FleetScoring.mayCarryPlate(confidence: confidence, markings: markings, vehicle: vehicle)
            ? identity : identity.redactingRegistration()
    }

    private func enqueue(_ dto: SightingSubmissionDTO, in context: ModelContext) {
        guard let payload = try? JSONEncoder.withISODates.encode(dto) else { return }
        context.insert(PendingSubmission(idempotencyKey: OutboxDrainer.idempotencyKey(for: dto),
                                         payloadJSON: payload))
    }

    /// The user vouches that a below-threshold detection really is a
    /// government vehicle. It is queued at the persist floor, which the
    /// server files as `pending` moderation (no public plate, no exact geo).
    /// The reviewer says which place an ambiguous reading means ("Atlanta, GA"): re-resolve with that
    /// state, recorded as a human choice in the evidence trail.
    func chooseState(_ candidateID: UUID, _ state: String) {
        guard var result = lastResult,
              let index = result.candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        let c = result.candidates[index]
        let resolved = identityResolver.resolve(sceneText: c.vehicle.sceneText, plates: c.vehicle.plates,
                                                vehicleClass: c.vehicle.vehicleClass, markings: c.markings,
                                                enhancedText: c.vehicle.enhancedText, userState: state)
        result.candidates[index].identity = resolved
        lastResult = result
    }

    func confirm(_ candidateID: UUID) {
        guard var result = lastResult,
              let index = result.candidates.firstIndex(where: { $0.id == candidateID }),
              !result.candidates[index].confirmed, let modelContext else { return }
        var dto = result.candidates[index].submission
        dto.fleetConfidence = max(dto.fleetConfidence, gate.config.persistThreshold)
        // A confirmed review item is below the plate bar, so its identity carries no registration.
        dto.identity = result.candidates[index].identity?.redactingRegistration()
        enqueue(dto, in: modelContext)
        try? modelContext.save()
        result.candidates[index].confirmed = true
        lastResult = result
        statusText = "Recorded for moderator review"
    }

    private static func describe(_ m: FleetMarkings) -> [String] {
        var out: [String] = []
        if let service = m.serviceClassText { out.append("Service: \(service)") }
        if let agency = m.agencyText, agency.uppercased() != m.serviceClassText { out.append("Agency: \(agency)") }
        if let unit = m.unitNumber { out.append("Unit: \(unit)") }
        return out
    }

    private func handle(_ packet: FramePacket) async {
        lastPacket = packet
        hasReceivedFrame = true
        refreshPlateGate()
        guard let frame = try? await executor.submit(
            .init(pixelBuffer: packet.pixelBuffer), mode: .live) else { return }
        latestFrame = frame

        let result = await evaluateAndPersist(frame: frame, source: "live")
        if result.fleetCount == 0, !result.candidates.isEmpty {
            escalate(packet) // fleet evidence, not yet confident: look harder at this frame
        }
        if processingStill {
            return // a manual pass owns the status line right now
        }
        if result.fleetCount > 0 {
            statusText = result.watchlistHits > 0
                ? "Watchlist hit · \(result.watchlistHits)"
                : "Fleet vehicle recorded"
            // Rolling-buffer event clip around the trigger frame.
            if let clip = session.extractEventClip(triggerFrameIndex: Int(packet.sequenceNumber)) {
                latestEventClip = clip
            }
        } else {
            statusText = "Scanning for fleet vehicles"
        }
        PassiveCaptureStatus.shared.set(statusText: statusText,
                                        fleetHit: result.fleetCount > 0,
                                        modelStatus: modelStatus)
    }

    /// Re-analyze one promising live frame with the slower, thorough pass
    /// (tiled text + plate-rectangle reads). Rate-limited: it costs several
    /// Vision requests, so it must not run on every frame or heat the phone.
    private func escalate(_ packet: FramePacket) {
        guard !escalating, !processingStill, Date().timeIntervalSince(lastEscalation) > 6 else { return }
        escalating = true
        lastEscalation = Date()
        Task { [weak self] in
            guard let self else { return }
            defer { self.escalating = false }
            guard let frame = try? await self.executor.submit(
                FramePacketLike(pixelBuffer: packet.pixelBuffer), mode: .processAll) else { return }
            let result = await self.evaluateAndPersist(frame: frame, source: "live")
            if result.fleetCount > 0 {
                self.latestFrame = frame
                self.statusText = result.watchlistHits > 0
                    ? "Watchlist hit · \(result.watchlistHits)" : "Fleet vehicle recorded"
            } else if !result.candidates.isEmpty {
                self.statusText = "Possible fleet vehicle — tap the shutter to review"
            }
        }
    }

    /// LLM-first markings parse with deterministic fallback. FleetMarkings
    /// LLM runs on-device (Apple Intelligence); pre-iOS 26 falls back to the
    /// regex heuristics without a network round-trip either.
    private func parseMarkings(_ observations: [SceneTextObservation]) async -> FleetMarkings {
        let heuristic = SceneTextHeuristics.parse(observations)
        #if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            let lines = observations.map(\.text)
            if let claim = await FleetMarkingsLLMParser.parse(lines) {
                // The LLM can invent fields from garbled text ("Hybridand" as a service): its output is a
                // claim, kept only where the OCR text supports it.
                return SceneTextHeuristics.grounded(claim, in: observations, fallback: heuristic)
            }
        }
        #endif
        return heuristic
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}
