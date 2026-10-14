import CaptureKit
import FeedIngest
import Network
import PlateSync
import Foundation
import PlateKit
import SwiftData
import VehicleML
import AVFoundation

/// Fixed-camera ingest. v1 watches a folder that IP cameras FTP snapshots
/// into (every Reolink/Amcrest-class camera supports this) — zero SDKs, no
/// cloud accounts, cameras never touch the internet, which is on-mission.
/// v2: Bonjour-advertised HTTP snapshot endpoint for cameras/phones to POST
/// directly. v3: RTSP ingest for cameras that only expose RTSP.
@MainActor
final class HubController: ObservableObject {
    @Published private(set) var ingestFolder: URL
    @Published private(set) var framesAnalyzed = 0
    @Published private(set) var fleetHitsToday = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var snapshotServerStatus = "Stopped"
    @Published private(set) var snapshotPort: UInt16 = 0
    @Published private(set) var rtspServerStatus = "Stopped"
    @Published private(set) var rtspStreams: [String: RTSPStreamStatus] = [:]

    private let pipeline = PlateAnalysisPipeline()
    /// Detector models (plate / vehicle) hot-swap in here as they install; empty = baseline Vision.
    private let contextBox = AnalysisContextBox()
    private let modelManager: ModelManager
    private let identityResolver = IdentityResolver()
    private var deduper = SightingDeduper()
    /// Public camera feeds (docs/FEED-SOURCES.md). Only sources a person confirmed the terms of are polled.
    let feedRunner = FeedRunner()
    var feedsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "PlateWatchHub/feeds.json")
    }
    @Published private(set) var modelStatus = "baseline vision"
    private let fileSource = FileFrameSource()
    private let gate = RedactionGate(config: .standard)
    private var watchDescriptor: DispatchSourceFileSystemObject?

    private var modelContext: ModelContext?
    /// Hub operator-set location bucket (these are fixed installations —
    /// the geohash-6 of the camera's own location).
    var homeGeohash6 = "" { didSet { platesAllowed = Self.platesAllowed(forGeohash6: homeGeohash6) } }

    /// Plate recognition runs only where it is permitted for this camera's location (PlateKit.JurisdictionPolicy):
    /// off in/near restricted states and when the location is unknown (fail closed).
    private(set) var platesAllowed = false

    static func platesAllowed(forGeohash6 geohash: String) -> Bool {
        JurisdictionPolicy.mayReadPlates(near: .init(geohash6: geohash))
    }

    // Bonjour snapshot server
    private var snapshotListener: NWListener?
    private let snapshotQueue = DispatchQueue(label: "org.platewatch.hub.snapshot", qos: .userInitiated)
    private var bonjourRegistration: NetService?

    // RTSP streams
    private var rtspStreamsMap: [String: RTSPStreamHandler] = [:]
    private let rtspQueue = DispatchQueue(label: "org.platewatch.hub.rtsp", qos: .userInitiated)

    /// Owned by the App (not a view), so ingest runs from launch — the menu-bar popover only
    /// exists once someone opens it.
    init(context: ModelContext? = nil) {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.ingestFolder = docs.appending(path: "PlateWatch-Ingest", directoryHint: .isDirectory)
        self.modelContext = context
        self.homeGeohash6 = UserDefaults.standard.string(forKey: "hubGeohash6") ?? ""   // not only once the menu opens
        self.platesAllowed = Self.platesAllowed(forGeohash6: homeGeohash6)
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "PlateWatchHub/Models", directoryHint: .isDirectory)
        self.modelManager = ModelManager(config: .init(
            registryURL: URL(string: "https://raw.githubusercontent.com/noktirnal42/PlateWatch/main/models/registry.json")!,
            cacheDirectory: support))
        try? FileManager.default.createDirectory(at: ingestFolder, withIntermediateDirectories: true)
        startWatching()
        Task { await refreshModels() }
        startFeeds()
        #if DEBUG
        if CommandLine.arguments.contains("-PWImportAustin") { Task { await importAustinCameras() } }
        #endif
        processNewFiles()   // pick up anything dropped while the Hub was not running
    }

    /// Imports the City of Austin traffic-camera catalogue (Socrata `b4k4-adkb`, listed Public Domain) into `feeds.json`.
    /// New cameras arrive **unconfirmed** and are not polled until a person reads the image host's terms and records
    /// them; existing confirmations are preserved (`FeedCatalogue.merged`). One catalogue request, identifying User-Agent.
    @Published private(set) var importStatus = ""

    func importAustinCameras() async {
        importStatus = "Importing…"
        let dataset = URL(string: "https://data.austintexas.gov/resource/b4k4-adkb")!
        var components = URLComponents(url: dataset.appendingPathExtension("json"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "$limit", value: "5000"),
                                 URLQueryItem(name: "$where", value: "camera_status='TURNED_ON'")]
        var request = URLRequest(url: components.url!)
        request.setValue(FeedRunner.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 60
        do {
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: dataset, attribution: "City of Austin")
            let existing = (try? FeedCatalogue.load(from: feedsFile)) ?? FeedCatalogue()
            let merged = existing.merged(with: result.sources)
            try merged.write(to: feedsFile)
            startFeeds()
            importStatus = "Imported \(result.sources.count) cameras (\(result.skippedCount) skipped); \(merged.awaitingTerms.count) awaiting terms"
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    /// Shows `feeds.json` in Finder, where a person records each source's terms (termsURL, termsReadOn, automatedUseAllowed).
    func revealFeedsFile() {
        if !FileManager.default.fileExists(atPath: feedsFile.path) { try? FeedCatalogue().write(to: feedsFile) }
        NSWorkspace.shared.activateFileViewerSelecting([feedsFile])
    }

    /// Loads `feeds.json` and starts polling the confirmed sources. Missing/corrupt file = no feeds (never a crash).
    func startFeeds() {
        guard let catalogue = try? FeedCatalogue.load(from: feedsFile) else {
            feedRunner.stop()
            return
        }
        feedRunner.start(catalogue: catalogue) { [weak self] data, source in
            await self?.analyseFeedFrame(data, from: source)
        }
    }

    /// Returns a summary of feed hosts from `feeds.json` for the review UI.
    /// Returns empty array if file is missing or corrupt.
    func feedHosts() -> [FeedHostSummary] {
        guard let catalogue = try? FeedCatalogue.load(from: feedsFile) else { return [] }
        return catalogue.hosts()
    }

    /// Confirms terms for all cameras on a host.
    /// Loads the catalogue, applies the confirmation, writes it back, and restarts feeds.
    func confirmFeedTerms(host: String, licenseClass: FeedTerms.LicenseClass, termsURL: URL, attribution: String) throws {
        guard let catalogue = try? FeedCatalogue.load(from: feedsFile) else { return }
        let updated = try catalogue.confirmingTerms(
            forHost: host,
            licenseClass: licenseClass,
            termsURL: termsURL,
            attribution: attribution,
            now: Date()
        )
        try updated.write(to: feedsFile)
        startFeeds()
    }

    /// Revokes terms confirmation for all cameras on a host.
    func revokeFeedTerms(host: String) {
        guard let catalogue = try? FeedCatalogue.load(from: feedsFile) else { return }
        let updated = catalogue.revokingConfirmation(forHost: host)
        try? updated.write(to: feedsFile)
        startFeeds()
    }

    /// One frame from a public feed. Everything is decided from *that source*: its catalogued position (identity hint
    /// and the plate-recognition jurisdiction gate), and the frame's real size (analysis tier). The frame lives in
    /// memory only.
    func analyseFeedFrame(_ data: Data, from source: PublicFeedSource) async {
        guard let buffer = FileFrameSource.pixelBuffer(from: data) else { return }
        let tier = source.analysisTier(frameLongSide: max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)))
        let readPlates = source.mayResolveIdentity && Self.platesAllowed(forGeohash6: source.geohash6)
        guard let frame = try? await pipeline.analyze(.init(pixelBuffer: buffer),
                                                      context: frameContext(contextBox, for: buffer, readPlates: readPlates)) else { return }
        framesAnalyzed += 1
        recordFleetHits(in: frame, tier: tier, geohash6: source.geohash6, mayResolveIdentity: source.mayResolveIdentity,
                        sourceID: source.id.uuidString)
    }

    /// Installs the detector models (registry, or a developer override `Local/<task>.mlmodel`). Best-effort:
    /// failure leaves baseline Vision active.
    func refreshModels() async {
        let box = contextBox, manager = modelManager
        let count = await Task.detached(priority: .utility) {
            await manager.install(tasks: ["vehicle-detection", "plate-detection"], into: box)
        }.value
        modelStatus = count == 0 ? "baseline vision" : "CoreML active (\(count) models)"
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

    /// Start the Bonjour-advertised snapshot HTTP server.
    /// - Parameter port: Preferred port (default 8088). If it is taken — another local server often
    ///   holds 8088 — the Hub falls back to an OS-assigned port; Bonjour advertises whichever it got,
    ///   and the menu shows it.
    func startSnapshotServer(port: UInt16 = 8088) async {
        guard snapshotListener == nil else { return }

        let params = NWParameters.tcp
        params.includePeerToPeer = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port) ?? .any)
            self.snapshotListener = listener

            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in
                    self?.handleSnapshotConnection(connection)
                }
            }

            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor in
                    switch state {
                    case .ready:
                        if let port = listener.port {
                            self?.snapshotPort = port.rawValue
                            self?.snapshotServerStatus = "Listening on port \(port.rawValue)"
                            self?.advertiseBonjour(port: port.rawValue)
                        }
                    case .failed(let error):
                        self?.snapshotListener = nil
                        if port != 0 {
                            // Port busy (or refused): take any free one instead of staying dark.
                            self?.snapshotServerStatus = "Port \(port) unavailable (\(error.localizedDescription)); trying another"
                            await self?.startSnapshotServer(port: 0)
                        } else {
                            self?.snapshotServerStatus = "Failed: \(error.localizedDescription)"
                        }
                    case .cancelled:
                        self?.snapshotServerStatus = "Stopped"
                        self?.snapshotListener = nil
                    default:
                        break
                    }
                }
            }

            listener.start(queue: snapshotQueue)
        } catch {
            snapshotServerStatus = "Failed to start: \(error.localizedDescription)"
        }
    }

    /// Restart on a new preferred port (the menu's port field).
    func restartSnapshotServer(port: UInt16) async {
        stopSnapshotServer()
        await startSnapshotServer(port: port)
    }

    func stopSnapshotServer() {
        snapshotListener?.cancel()
        snapshotListener = nil
        bonjourRegistration?.stop()
        bonjourRegistration = nil
        snapshotServerStatus = "Stopped"
        snapshotPort = 0
    }

    /// Start an RTSP stream from the given URL
    func startRTSPStream(url: String) {
        guard rtspStreamsMap[url] == nil else {
            rtspServerStatus = "Stream already running: \(url)"
            return
        }
        
        let handler = RTSPStreamHandler(
            url: url,
            pipeline: pipeline,
            contextBox: contextBox,
            gate: gate,
            homeGeohash6: homeGeohash6,
            modelContext: modelContext)
        
        handler.statusUpdate = { [weak self] status in
            Task { @MainActor [weak self] in
                self?.rtspStreams[url] = status
                self?.updateRTSPStatus()
            }
        }
        
        rtspStreamsMap[url] = handler
        rtspStreams[url] = RTSPStreamStatus(url: url)
        handler.start()
        rtspServerStatus = "Running \(rtspStreams.count) stream(s)"
    }
    
    /// Stop an RTSP stream
    func stopRTSPStream(url: String) {
        rtspStreamsMap[url]?.stop()
        rtspStreamsMap.removeValue(forKey: url)
        rtspStreams.removeValue(forKey: url)
        rtspServerStatus = rtspStreams.isEmpty ? "Stopped" : "Running \(rtspStreams.count) stream(s)"
    }
    
    /// Stop all RTSP streams
    func stopAllRTSPStreams() {
        for (_, handler) in rtspStreamsMap {
            handler.stop()
        }
        rtspStreamsMap.removeAll()
        rtspStreams.removeAll()
        rtspServerStatus = "Stopped"
    }
    
    private func updateRTSPStatus() {
        if rtspStreams.isEmpty {
            rtspServerStatus = "Stopped"
        } else {
            let running = rtspStreams.values.filter { $0.status == "Running" || $0.status == "Connected" }.count
            rtspServerStatus = "Running \(running)/\(rtspStreams.count) stream(s)"
        }
    }

    private func advertiseBonjour(port: UInt16) {
        let service = NetService(domain: "local.", type: "_platewatch-snapshot._tcp", name: "PlateWatch Hub", port: Int32(port))
        let txtData = ["path": Data("/snapshot".utf8), "version": Data("1".utf8)]
        service.setTXTRecord(NetService.data(fromTXTRecord: txtData))
        service.publish()
        bonjourRegistration = service
    }

    @MainActor
    private func handleSnapshotConnection(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .failed(let error) = state {
                print("Snapshot connection failed: \(error)")
            }
        }
        connection.start(queue: snapshotQueue)
        receiveHTTPRequest(on: connection, buffer: HTTPRequestBuffer())
    }

    /// Reads until one whole request has arrived (by Content-Length), then answers it.
    /// The buffer is a value passed along the read chain, so nothing is shared across connections.
    private func receiveHTTPRequest(on connection: NWConnection, buffer: HTTPRequestBuffer) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { connection.cancel(); return }
            var buffer = buffer
            guard let data, !data.isEmpty else {
                if error != nil || isComplete { connection.cancel() }
                return
            }
            switch buffer.append(data) {
            case .needMore:
                if buffer.takeContinueRequest() {
                    connection.send(content: HTTPResponses.continue100, completion: .contentProcessed { _ in })
                }
                if isComplete { connection.cancel() } else { self.receiveHTTPRequest(on: connection, buffer: buffer) }
            case .reject(let status, let reason):
                self.sendHTTPResponse(on: connection, status: status, body: reason)
            case .complete(let request):
                Task { @MainActor [weak self] in
                    await self?.handle(request, on: connection)
                }
            }
        }
    }

    @MainActor
    private func handle(_ request: HTTPRequest, on connection: NWConnection) async {
        switch (request.method, request.path.split(separator: "?").first.map(String.init) ?? request.path) {
        case ("POST", "/snapshot"):
            await processSnapshotBody(request.body, on: connection)
        case ("GET", "/health"):
            sendHTTPResponse(on: connection, status: 200,
                             body: "PlateWatch Hub | models: \(modelStatus) | feeds: \(feedRunner.status) | frames analysed: \(framesAnalyzed) | fleet hits today: \(fleetHitsToday) | outbox: \(pendingCount)")
        case (_, "/snapshot"), (_, "/health"):
            sendHTTPResponse(on: connection, status: 405, body: "Method Not Allowed")
        default:
            sendHTTPResponse(on: connection, status: 404, body: "Not Found")
        }
    }

    @MainActor
    private func processSnapshotBody(_ data: Data, on connection: NWConnection) async {
        guard !data.isEmpty, let buffer = FileFrameSource.pixelBuffer(from: data) else {
            sendHTTPResponse(on: connection, status: 400, body: "Invalid image data")
            return
        }
        do {
            let frame = try await pipeline.analyze(.init(pixelBuffer: buffer), context: frameContext(contextBox, for: buffer, readPlates: platesAllowed))
            framesAnalyzed += 1
            let tier = AnalysisTier.tier(forLongSide: max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)))
            let recorded = recordFleetHits(in: frame, tier: tier)
            let keys = recorded.agencyKeys.isEmpty ? "" : "; " + recorded.agencyKeys.joined(separator: ", ")
            sendHTTPResponse(on: connection, status: 200,
                             body: frame.vehicles.isEmpty ? "OK (no vehicles)" : "OK (fleet hits: \(recorded.hits)\(keys); tier: \(tier.rawValue); plates read: \(frame.vehicles.flatMap(\.plates).count))")
        } catch {
            sendHTTPResponse(on: connection, status: 500, body: "Processing error")
        }
    }

    /// Gate each vehicle and queue fleet hits for sync. Shared by the folder watch and the HTTP
    /// endpoint so both apply identical rules. Returns the number of fleet hits.
    @discardableResult
    private func recordFleetHits(in frame: DetectionFrame, tier: AnalysisTier,
                                 geohash6: String? = nil, mayResolveIdentity: Bool = true,
                                 sourceID: String = "home") -> (hits: Int, agencyKeys: [String]) {
        let geohash6 = geohash6 ?? homeGeohash6
        var hits = 0
        var agencyKeys: [String] = []
        for vehicle in frame.vehicles {
            let (confidence, markings) = FleetScoring.vehicleGateScore(gate: gate, vehicle: vehicle)
            guard gate.verdict(fleetConfidence: confidence) == .persistAndSync else { continue }
            // The frame's tier is the ceiling; with the vehicle detector loaded the vehicle's own pixel size can only
            // lower it (a 1080p frame can hold a 50 px vehicle). Without the detector the "vehicle" boxes are pseudo-boxes
            // grown from text regions, so their size means nothing and the frame tier stands.
            var vehicleTier = tier
            if contextBox.current.models["vehicle-detection"] != nil {
                let longSide = max(vehicle.boundingBox.width * frame.imageSize.width,
                                   vehicle.boundingBox.height * frame.imageSize.height)
                vehicleTier = AnalysisTier.combined(frame: tier, vehicle: AnalysisTier.tier(forVehicleLongSide: Int(longSide)))
            }
            let identity = mayResolveIdentity
                ? feedIdentity(vehicle: vehicle, markings: markings, confidence: confidence, tier: vehicleTier, geohash6: geohash6)
                : nil
            // A fixed camera sees the same parked vehicle in every frame: one sighting per vehicle per window.
            let dedupeKey = SightingDeduper.key(
                source: sourceID, agencyKey: identity?.agency?.agencyKey,
                unit: markings.unitNumber ?? identity?.unitNumbers.first,
                plate: vehicle.plates.first?.best.map { Plate.normalize($0.text) },
                vehicleClass: vehicle.vehicleClass.rawValue)
            guard deduper.shouldRecord(key: dedupeKey) else { continue }
            hits += 1
            fleetHitsToday += 1
            if let key = identity?.agency?.agencyKey { agencyKeys.append(key) }
            guard let context = modelContext else { continue }
            let dto = SightingSubmissionDTO(
                capturedAt: frame.timestamp,
                geohash6: geohash6,
                deviceIDHash: (try? DeviceIdentity.loadOrCreate().publicKeyHash) ?? "unknown",
                fleetConfidence: confidence,
                plate: vehicle.plates.first?.best.map(PlateDTO.init),
                vehicle: VehicleObservationDTO(vehicle),
                markings: FleetMarkingsDTO(markings),
                identity: identity)
            if let payload = try? JSONEncoder.withISODates.encode(dto) {
                context.insert(PendingSubmission(
                    idempotencyKey: OutboxDrainer.idempotencyKey(for: dto),
                    payloadJSON: payload))
                try? context.save()
                pendingCount += 1
            }
        }
        return (hits, agencyKeys)
    }

    /// Identity for a sighting from a fixed camera: the camera's operator-set position is the location hint
    /// (never this Mac's), review is forced below full resolution, and the smallest frames assert no identity at
    /// all (docs/FEED-SOURCES.md §1-2).
    private func feedIdentity(vehicle: VehicleObservation, markings: FleetMarkings, confidence: Double,
                              tier: AnalysisTier, geohash6: String) -> VehicleIdentity? {
        guard tier != .appearanceOnly else { return nil }
        return identityResolver.syncIdentity(vehicle: vehicle, markings: markings, confidence: confidence,
                                             location: .init(geohash6: geohash6),
                                             forceReview: !tier.identityMayBeConfirmed)
    }

    private func sendHTTPResponse(on connection: NWConnection, status: Int, body: String) {
        connection.send(content: HTTPResponses.text(status: status, body), completion: .contentProcessed { _ in
            connection.cancel()
        })
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
        // A directory write event fires per file; skip files a previous pass is already handling.
        let images = all.filter {
            ["jpg", "jpeg", "png"].contains($0.pathExtension.lowercased()) && !inFlight.contains($0.path)
        }
        inFlight.formUnion(images.map(\.path))

        Task {
            for url in images {
                defer { inFlight.remove(url.path) }
                guard let buffer = FileFrameSource.pixelBuffer(from: url) else { continue }
                let frame = try? await pipeline.analyze(
                    .init(pixelBuffer: buffer),
                    context: frameContext(contextBox, for: buffer, readPlates: platesAllowed))
                filesProcessed += 1
                framesAnalyzed = filesProcessed
                guard let frame else {
                    try? fm.removeItem(at: url) // undecodable input, discard
                    continue
                }
                recordFleetHits(in: frame, tier: AnalysisTier.tier(forLongSide: max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))))
                // Rolling source media: hub keeps only fleet-hit crops,
                // never the raw camera flow (LEGAL-ETHICS).
                try? fm.removeItem(at: url)
            }
        }
    }

    private var inFlight = Set<String>()
    private var filesProcessed = 0
}

/// The analysis context for one frame: the shared models plus the thorough text path only where the frame has
/// enough pixels to read lettering (docs/FEED-SOURCES.md §1 — recall collapses below ~480 px).
func frameContext(_ box: AnalysisContextBox, for buffer: CVPixelBuffer, readPlates: Bool) -> AnalysisContext {
    var context = box.current
    context.readPlates = readPlates
    let longSide = max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
    context.thorough = AnalysisTier.tier(forLongSide: longSide).thorough
    return context
}

/// Status of an RTSP stream
public struct RTSPStreamStatus: Sendable {
    public var url: String
    public var status: String
    public var framesAnalyzed: Int
    public var fleetHits: Int
    public var lastFrameTime: Date?
    
    public init(url: String) {
        self.url = url
        self.status = "Connecting..."
        self.framesAnalyzed = 0
        self.fleetHits = 0
    }
}

/// Handles a single RTSP stream connection and frame extraction
final class RTSPStreamHandler: @unchecked Sendable {
    private let url: String
    private let pipeline: PlateAnalysisPipeline
    private let contextBox: AnalysisContextBox
    private let gate: RedactionGate
    private let homeGeohash6: String
    private let modelContext: ModelContext?
    private var asset: AVAsset?
    private var reader: AVAssetReader?
    private var output: AVAssetReaderTrackOutput?
    private var isRunning = false
    private let queue = DispatchQueue(label: "org.platewatch.rtsp.stream", qos: .userInitiated)
    
    var statusUpdate: ((RTSPStreamStatus) -> Void)?
    var onFleetHit: ((DetectionFrame) -> Void)?
    
    init(url: String, pipeline: PlateAnalysisPipeline, contextBox: AnalysisContextBox, gate: RedactionGate,
         homeGeohash6: String, modelContext: ModelContext?) {
        self.url = url
        self.pipeline = pipeline
        self.contextBox = contextBox
        self.gate = gate
        self.homeGeohash6 = homeGeohash6
        self.modelContext = modelContext
        
        var status = RTSPStreamStatus(url: url)
        self.statusUpdate?(status)
    }
    
    func start() {
        guard !isRunning else { return }
        isRunning = true
        
        queue.async { [weak self] in
            self?.setupAndRun()
        }
    }
    
    func stop() {
        isRunning = false
        reader?.cancelReading()
        reader = nil
        output = nil
        asset = nil
        
        var status = RTSPStreamStatus(url: url)
        status.status = "Stopped"
        statusUpdate?(status)
    }
    
    private func setupAndRun() {
        guard let streamURL = URL(string: url) else {
            updateStatus { $0.status = "Invalid URL" }
            return
        }
        
        // Use AVAsset for RTSP - it handles connection, reconnection, and frame extraction
        let asset = AVAsset(url: streamURL)
        self.asset = asset
        
        // Load tracks on the queue to avoid Sendable issues
        queue.async { [weak self] in
            self?.loadTracksAndStart(asset: asset)
        }
    }
    
    private func loadTracksAndStart(asset: AVAsset) {
        // Load tracks synchronously on the queue
        let semaphore = DispatchSemaphore(value: 0)
        var tracksResult: Result<[AVAssetTrack], Error>?
        
        asset.loadTracks(withMediaType: .video) { tracks, error in
            if let error = error {
                tracksResult = .failure(error)
            } else if let tracks = tracks {
                tracksResult = .success(tracks)
            }
            semaphore.signal()
        }
        semaphore.wait()
        
        guard let tracksResult = tracksResult else {
            updateStatus { $0.status = "Failed to load tracks" }
            return
        }
        
        switch tracksResult {
        case .success(let tracks):
            guard let videoTrack = tracks.first else {
                updateStatus { $0.status = "No video track" }
                return
            }
            
            do {
                let reader = try AVAssetReader(asset: asset)
                let outputSettings: [String: Any] = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                let output = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
                output.alwaysCopiesSampleData = false
                
                guard reader.canAdd(output) else {
                    updateStatus { $0.status = "Cannot add output" }
                    return
                }
                reader.add(output)
                
                updateStatus { $0.status = "Connected" }
                
                if reader.startReading() {
                    self.reader = reader
                    self.output = output
                    processFrames()
                } else {
                    updateStatus { $0.status = "Failed to start: \(reader.error?.localizedDescription ?? "unknown")" }
                }
            } catch {
                updateStatus { $0.status = "Error: \(error.localizedDescription)" }
            }
        case .failure(let error):
            updateStatus { $0.status = "Error: \(error.localizedDescription)" }
        }
    }
    
    private func processFrames() {
        guard let reader = reader, let output = output else { return }
        
        var frameCount = 0
        var status = RTSPStreamStatus(url: url)
        status.status = "Running"
        statusUpdate?(status)
        
        while isRunning && reader.status == .reading {
            guard let sampleBuffer = output.copyNextSampleBuffer() else {
                // No more frames or end of stream - wait and check again
                Thread.sleep(forTimeInterval: 0.033) // ~30 fps
                continue
            }
            
            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
                continue
            }
            
            let timestamp = Date()
            frameCount += 1
            
            // Analyze every 3rd frame to avoid thermal throttling
            if frameCount % 3 == 0 {
                let packet = FramePacket(
                        pixelBuffer: pixelBuffer,
                        timestamp: timestamp,
                        sequenceNumber: UInt64(frameCount))
                    
                    Task { @Sendable [weak self] in
                        guard let self else { return }
                        do {
                            let frame = try await pipeline.analyze(
                                FramePacketLike(pixelBuffer: packet.pixelBuffer),
                                context: frameContext(contextBox, for: packet.pixelBuffer,
                                                      readPlates: HubController.platesAllowed(forGeohash6: homeGeohash6)))
                            
                            await MainActor.run {
                                self.handleFrame(frame, timestamp: timestamp)
                            }
                        } catch {
                            print("RTSP analysis error: \(error)")
                        }
                    }
            }
            
            // Update status periodically
            if frameCount % 90 == 0 {
                updateStatus { s in
                    s.framesAnalyzed = frameCount
                    s.lastFrameTime = timestamp
                }
            }
        }
        
        // Handle reader status changes
        switch reader.status {
        case .completed:
            updateStatus { $0.status = "Stream ended" }
        case .failed:
            updateStatus { $0.status = "Failed: \(reader.error?.localizedDescription ?? "unknown")" }
        case .cancelled:
            updateStatus { $0.status = "Cancelled" }
        default:
            break
        }
        
        isRunning = false
    }
    
    private func handleFrame(_ frame: DetectionFrame, timestamp: Date) {
        guard !frame.vehicles.isEmpty else { return }
        
        var fleetHits = 0
        for vehicle in frame.vehicles {
            let (confidence, markings) = FleetScoring.vehicleGateScore(gate: gate, vehicle: vehicle)
            if gate.verdict(fleetConfidence: confidence) == .persistAndSync {
                fleetHits += 1
                if let context = modelContext {
                    let dto = SightingSubmissionDTO(
                        capturedAt: timestamp,
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
                    }
                }
            }
        }
        
        if fleetHits > 0 {
            updateStatus { s in
                s.fleetHits += fleetHits
            }
        }
    }
    
    private func updateStatus(_ transform: @escaping (inout RTSPStreamStatus) -> Void) {
        var status = RTSPStreamStatus(url: url)
        transform(&status)
        statusUpdate?(status)
    }
}

import AppKit
import Darwin
