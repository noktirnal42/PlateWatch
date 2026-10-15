import CaptureKit
import FeedIngest
import Network
import PlateSync
import Foundation
import PlateKit
import SwiftData
import VehicleML
import AVFoundation
import CoreImage

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
    @Published private(set) var feedFramesAnalyzed = 0
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
    let favorites = FeedFavorites()
    private var activeFeedSources: [UUID: PublicFeedSource] = [:]
    var feedsFile: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appending(path: "PlateWatchHub/feeds.json")
    }
    @Published private(set) var modelStatus = "baseline vision"
    private let fileSource = FileFrameSource()
    private let gate = RedactionGate(config: .standard)
    private var watchDescriptor: DispatchSourceFileSystemObject?

    var agentBridge: HubAgentBridge?
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
        if let index = CommandLine.arguments.firstIndex(of: "-PWImportCatalogues"),
           CommandLine.arguments.indices.contains(index + 1) {
            let keys = Set(CommandLine.arguments[index + 1].split(separator: ",").map(String.init))
            Task {
                for choice in OpenCatalogue.allCases where keys.contains(choice.key) { await importCatalogue(choice) }
            }
        }
        #endif
        processNewFiles()   // pick up anything dropped while the Hub was not running
    }

    /// Imports the City of Austin traffic-camera catalogue (Socrata `b4k4-adkb`, listed Public Domain) into `feeds.json`.
    /// New cameras arrive **unconfirmed** and are not polled until a person reads the image host's terms and records
    /// them; existing confirmations are preserved (`FeedCatalogue.merged`). One catalogue request, identifying User-Agent.
    @Published private(set) var importStatus = ""
    private static let maxFeedAnalyses = 2
    private var feedAnalysesInFlight = 0
    /// Frames skipped because analysis was already at capacity.
    @Published private(set) var framesDropped = 0

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
            let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: dataset, attribution: "City of Austin", state: "TX")
            let existing = (try? FeedCatalogue.load(from: feedsFile)) ?? FeedCatalogue()
            let merged = existing.merged(with: result.sources)
            try merged.write(to: feedsFile)
            startFeeds()
            importStatus = "Imported \(result.sources.count) cameras (\(result.skippedCount) skipped); \(merged.awaitingTerms.count) awaiting terms"
        } catch {
            importStatus = "Import failed: \(error.localizedDescription)"
        }
    }

    enum OpenCatalogue: String, CaseIterable, Identifiable {
        case caltrans = "California — Caltrans (about 3,400 cameras)"
        case wsdot = "Washington — WSDOT (about 1,700; low-volume use only)"
        case iowa = "Iowa DOT (about 1,300)"
        case newMexico = "New Mexico — NMRoads (about 185 cameras)"
        case utah = "Utah — UDOT public GIS (about 480 cameras)"
        case oregon = "Oregon — TripCheck (about 1,160)"
        var id: String { rawValue }
        var key: String {
            switch self {
            case .caltrans: "caltrans"
            case .wsdot: "wsdot"
            case .iowa: "iowa"
            case .oregon: "oregon"
            case .utah: "utah"
            case .newMexico: "new-mexico"
            }
        }
    }

    /// Imports a public camera catalogue into `feeds.json`. Like Austin, every camera arrives **unconfirmed**: nothing is fetched
    /// from an image host until a person reviews and confirms that host's terms. Catalogue requests are spaced 1 s apart.
    func importCatalogue(_ choice: OpenCatalogue) async {
        importStatus = "Importing \(choice.rawValue)…"
        typealias Importers = CameraCatalogueImporters
        func fetch(_ url: URL) async throws -> Data {
            var request = URLRequest(url: url)
            request.setValue(FeedRunner.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 60
            let (data, response) = try await URLSession(configuration: .ephemeral).data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return data
        }
        func arcGIS(_ base: String, _ fields: Importers.ArcGISFields, _ op: Importers.Operator) async throws -> SocrataImportResult {
            var all: [PublicFeedSource] = [], skipped: [SkipReason] = []
            var offset = 0
            for _ in 0..<20 {
                let url = URL(string: "\(base)/query?where=1%3D1&outFields=*&outSR=4326&f=json&resultOffset=\(offset)&resultRecordCount=1000")!
                let (page, more) = try Importers.arcGIS(try await fetch(url), fields: fields, operator: op)
                all += page.sources; skipped += page.skipReasons
                guard more else { break }
                offset += 1000
                try await Task.sleep(for: .seconds(1))
            }
            return SocrataImportResult(sources: all, skippedCount: skipped.count, skipReasons: skipped)
        }
        do {
            let result: SocrataImportResult
            switch choice {
            case .caltrans:
                let op = Importers.Operator(datasetURL: URL(string: "https://cwwp2.dot.ca.gov/documentation/cctv/cctv.htm")!,
                                            attribution: "Caltrans", licenseClass: .publicDomain, refreshInterval: 300, state: "CA")
                var sources: [PublicFeedSource] = [], skipped: [SkipReason] = []
                for d in 1...12 {
                    let n = String(format: "%02d", d)
                    let data = try await fetch(URL(string: "https://cwwp2.dot.ca.gov/data/d\(d)/cctv/cctvStatusD\(n).json")!)
                    let r = try Importers.caltrans(data, district: d, operator: op)
                    sources += r.sources; skipped += r.skipReasons
                    try await Task.sleep(for: .seconds(1))
                }
                result = SocrataImportResult(sources: sources, skippedCount: skipped.count, skipReasons: skipped)
            case .newMexico:
                let url = URL(string: "https://servicev5.nmroads.com/RealMapWAR/GetCameraInfo")!
                result = try Importers.newMexicoRoads(try await fetch(url), operator: .init(
                    datasetURL: url, attribution: "New Mexico Department of Transportation / NMRoads",
                    licenseClass: .unknown, refreshInterval: 300, state: "NM"))
            case .utah:
                let base = "https://central.udot.utah.gov/server/rest/services/TOC_Devices/MapServer/0"
                let url = URL(string: "\(base)/query?where=1%3D1&outFields=*&outSR=4326&f=json&resultRecordCount=2000")!
                result = try Importers.utahTraffic(try await fetch(url), operator: .init(
                    datasetURL: URL(string: base)!, attribution: "Utah Department of Transportation",
                    licenseClass: .unknown, refreshInterval: 300, state: "UT"))
            case .oregon:
                let url = URL(string: "https://tripcheck.com/Scripts/map/data/cctvinventory.js")!
                result = try Importers.oregonTripCheck(try await fetch(url), operator: .init(
                    datasetURL: url, attribution: "Camera courtesy of ODOT / TripCheck",
                    licenseClass: .unknown, refreshInterval: 300, state: "OR"))
            case .wsdot:
                result = try await arcGIS("https://data.wsdot.wa.gov/arcgis/rest/services/TravelInformation/TravelInfoCamerasWeather/FeatureServer/0",
                    .init(name: "CameraTitle", image: "ImageURL", id: "OBJECTID"),
                    .init(datasetURL: URL(string: "https://data.wsdot.wa.gov/arcgis/rest/services/TravelInformation/TravelInfoCamerasWeather/FeatureServer/0")!,
                          attribution: "Washington State DOT", licenseClass: .unknown, refreshInterval: 600, state: "WA"))
            case .iowa:
                result = try await arcGIS("https://services.arcgis.com/8lRhdTsQyJpO52F1/arcgis/rest/services/Traffic_Cameras_View/FeatureServer/0",
                    .init(name: "Desc_", image: "ImageURL", id: "device_id", latitude: "latitude", longitude: "longitude"),
                    .init(datasetURL: URL(string: "https://services.arcgis.com/8lRhdTsQyJpO52F1/arcgis/rest/services/Traffic_Cameras_View/FeatureServer/0")!,
                          attribution: "Iowa DOT (CC BY 4.0)", licenseClass: .openLicence, refreshInterval: 300, state: "IA"))

            }
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
            activeFeedSources = [:]
            stopLiveFeed()
            feedRunner.stop()
            return
        }
        activeFeedSources = Dictionary(uniqueKeysWithValues: catalogue.sources.map { ($0.id, $0) })
        if let liveFeed, activeFeedSources[liveFeed.id]?.mayBeAnalysed != true { stopLiveFeed() }
        feedRunner.start(catalogue: catalogue, blockedIDs: favorites.blockedIDs) { [weak self] data, source in
            await self?.analyseFeedFrame(data, from: source)
        } analyseVideoFrame: { [weak self] box, source in
            await self?.analyseFeedVideoFrame(box.buffer, from: source)
        }
    }

    @Published private(set) var liveFeed: PublicFeedSource?
    @Published private(set) var liveFeedFrame: WebFeedFrame?
    @Published private(set) var liveFeedStatus = ""

    func openFeedInLive(_ source: PublicFeedSource) {
        guard source.kind == .snapshotJPEG, source.mayBeAnalysed, !favorites.isBlocked(source.id) else { return }
        liveFeedFrame = nil
        liveFeedStatus = "Waiting for a frame…"
        liveFeed = source
    }

    func stopLiveFeed() {
        liveFeed = nil; liveFeedFrame = nil; liveFeedStatus = ""
    }

    /// An immediate, rate-limited first frame; subsequent frames come from the existing background poller.
    func loadLiveFeed() async {
        guard let source = liveFeed else { return }
        while !Task.isCancelled, liveFeed?.id == source.id {
            do {
                let data = try await feedRunner.fetchPreview(of: source)
                guard !Task.isCancelled, liveFeed?.id == source.id else { return }
                await analyseFeedFrame(data, from: source)
                return
            } catch {
                guard !Task.isCancelled, liveFeed?.id == source.id else { return }
                liveFeedStatus = error.localizedDescription
                guard let delay = (error as? FeedRunner.PreviewError)?.policyRetryDelay else { return }
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            }
        }
    }

    func toggleFeedBlock(_ id: UUID) {
        favorites.toggleBlocked(id)
        if favorites.isBlocked(id), liveFeed?.id == id { stopLiveFeed() }
        feedRunner.setBlocked(id, blocked: favorites.isBlocked(id))
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
        // A catalogue that cannot be read must surface as an error, not as a silent no-op the person takes for success.
        let catalogue = try FeedCatalogue.load(from: feedsFile)
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
    func revokeFeedTerms(host: String) throws {
        let catalogue = try FeedCatalogue.load(from: feedsFile)
        try catalogue.revokingConfirmation(forHost: host).write(to: feedsFile)
        startFeeds()
    }

    /// One frame from a public feed. Everything is decided from *that source*: its catalogued position (identity hint
    /// and the plate-recognition jurisdiction gate), and the frame's real size (analysis tier). The frame lives in
    /// memory only.
    func analyseFeedFrame(_ data: Data, from source: PublicFeedSource) async {
        // Analysis blocks threads (Vision OCR). With hundreds of cameras, unbounded concurrency starves the whole app
        // (even unrelated network requests never get scheduled), so at most `maxFeedAnalyses` frames are analysed at once and
        // the surplus is dropped — a camera is simply looked at again on its next refresh.
        guard feedAnalysesInFlight < Self.maxFeedAnalyses else {
            framesDropped += 1
            if liveFeed?.id == source.id { liveFeedStatus = "Analysis busy; waiting for the next camera refresh" }
            return
        }
        feedAnalysesInFlight += 1
        defer { feedAnalysesInFlight -= 1 }
        guard let buffer = FileFrameSource.pixelBuffer(from: data) else {
            if liveFeed?.id == source.id { liveFeedStatus = "Image unavailable or unreadable. Use ⦸ to block this camera." }
            return
        }
        let tier = source.analysisTier(frameLongSide: max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)))
        let readPlates = source.mayResolveIdentity && Self.platesAllowed(forGeohash6: source.geohash6)
        guard let frame = try? await pipeline.analyze(.init(pixelBuffer: buffer),
                                                      context: frameContext(contextBox, for: buffer, readPlates: readPlates, publicFeed: true)) else { return }
        framesAnalyzed += 1
        feedFramesAnalyzed += 1
        // Permissions can be revoked while Vision is processing a frame.
        guard !favorites.isBlocked(source.id),
              let current = activeFeedSources[source.id],
              current.mayBeAnalysed else { return }
        let recorded = recordFleetHits(in: frame, tier: tier, geohash6: source.geohash6,
                                       mayResolveIdentity: source.mayResolveIdentity, sourceID: source.id.uuidString,
                                       source: EvidenceCrop.SourceFrame(pixelBuffer: buffer))
        if liveFeed?.id == source.id,
           let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent) {
            liveFeedFrame = .init(image: image, result: liveResult(frame, hits: recorded.hits), updatedAt: Date())
            liveFeedStatus = "Background analysis · refreshed at the camera's interval"
        }
    }

    /// One decoded frame from a continuous video feed (HLS today, RTSP via a
    /// future VLCKit path). Same rules, cadence cap and tiering as snapshot
    /// frames — only the transport differs. The decoder taps ~15 fps; the
    /// concurrency cap is what bounds the analysis cost.
    func analyseFeedVideoFrame(_ buffer: CVPixelBuffer, from source: PublicFeedSource) async {
        guard feedAnalysesInFlight < Self.maxFeedAnalyses else { framesDropped += 1; return }
        feedAnalysesInFlight += 1
        defer { feedAnalysesInFlight -= 1 }
        let tier = source.analysisTier(frameLongSide: max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)))
        let readPlates = source.mayResolveIdentity && Self.platesAllowed(forGeohash6: source.geohash6)
        guard let frame = try? await pipeline.analyze(.init(pixelBuffer: buffer),
                                                      context: frameContext(contextBox, for: buffer, readPlates: readPlates, publicFeed: true)) else { return }
        framesAnalyzed += 1
        feedFramesAnalyzed += 1
        guard !favorites.isBlocked(source.id),
              let current = activeFeedSources[source.id],
              current.mayBeAnalysed else { return }
        let recorded = recordFleetHits(in: frame, tier: tier, geohash6: source.geohash6,
                                       mayResolveIdentity: source.mayResolveIdentity, sourceID: source.id.uuidString,
                                       source: EvidenceCrop.SourceFrame(pixelBuffer: buffer))
        if liveFeed?.id == source.id,
           let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer), from: CIImage(cvPixelBuffer: buffer).extent) {
            liveFeedFrame = .init(image: image, result: liveResult(frame, hits: recorded.hits), updatedAt: Date())
            liveFeedStatus = "Live video analysis · sampled from the stream"
        }
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
    nonisolated private func receiveHTTPRequest(on connection: NWConnection, buffer: HTTPRequestBuffer) {
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
            let recorded = recordFleetHits(in: frame, tier: tier,
                                           source: EvidenceCrop.SourceFrame(pixelBuffer: buffer))
            let keys = recorded.agencyKeys.isEmpty ? "" : "; " + recorded.agencyKeys.joined(separator: ", ")
            sendHTTPResponse(on: connection, status: 200,
                             body: frame.vehicles.isEmpty ? "OK (no vehicles)" : "OK (fleet hits: \(recorded.hits)\(keys); tier: \(tier.rawValue); plates read: \(frame.vehicles.flatMap(\.plates).count))")
        } catch {
            sendHTTPResponse(on: connection, status: 500, body: "Processing error")
        }
    }

    /// Gate each vehicle and queue fleet hits for sync. Shared by the folder watch and the HTTP
    /// endpoint so both apply identical rules. Returns the number of fleet hits.
    /// `source` is the analysed frame as a bitmap: when present, every recorded hit
    /// carries an evidence crop of the vehicle (redacted per `EvidenceCrop` policy).
    @discardableResult
    private func recordFleetHits(in frame: DetectionFrame, tier: AnalysisTier,
                                 geohash6: String? = nil, mayResolveIdentity: Bool = true,
                                 sourceID: String = "home",
                                 source: EvidenceCrop.SourceFrame? = nil) -> (hits: Int, agencyKeys: [String]) {
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
            let crop = source.flatMap { EvidenceCrop.make(source: $0, vehicle: vehicle, others: frame.vehicles) }
            let dto = SightingSubmissionDTO(
                capturedAt: frame.timestamp,
                geohash6: geohash6,
                cropHashSHA256: crop?.sha256Hex,
                cropJPEGBase64: crop?.base64,
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

    nonisolated private func sendHTTPResponse(on connection: NWConnection, status: Int, body: String) {
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

    /// One frame from a live camera or a video file, shown in the console. Same rules as every other source
    /// (jurisdiction gate, redaction gate, de-dup, outbox); the frame stays in memory. Overlay labels never include
    /// plate text — only the vehicle class and the fleet score.
    func analyseLive(_ buffer: CVPixelBuffer, sourceID: String) async -> LiveFrameResult? {
        guard let frame = try? await pipeline.analyze(
            .init(pixelBuffer: buffer),
            context: frameContext(contextBox, for: buffer, readPlates: platesAllowed)) else { return nil }
        framesAnalyzed += 1
        let tier = AnalysisTier.tier(forLongSide: max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer)))
        let recorded = recordFleetHits(in: frame, tier: tier, sourceID: sourceID,
                                       source: EvidenceCrop.SourceFrame(pixelBuffer: buffer))
        return liveResult(frame, hits: recorded.hits)
    }

    private func liveResult(_ frame: DetectionFrame, hits: Int) -> LiveFrameResult {
        let boxes = frame.vehicles.map { vehicle -> LiveFrameResult.Box in
            let (confidence, _) = FleetScoring.vehicleGateScore(gate: gate, vehicle: vehicle)
            return .init(id: vehicle.id, rect: vehicle.boundingBox,
                         label: "\(vehicle.vehicleClass.rawValue) \(Int(confidence * 100))%",
                         isFleet: gate.verdict(fleetConfidence: confidence) == .persistAndSync)
        }
        return LiveFrameResult(boxes: boxes, hits: hits)
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
                guard let frame else {
                    try? fm.removeItem(at: url) // undecodable input, discard
                    continue
                }
                framesAnalyzed += 1
                recordFleetHits(in: frame, tier: AnalysisTier.tier(forLongSide: max(CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))),
                                source: EvidenceCrop.SourceFrame(pixelBuffer: buffer))
                // Rolling source media: hub keeps only fleet-hit crops,
                // never the raw camera flow (LEGAL-ETHICS).
                try? fm.removeItem(at: url)
            }
        }
    }

    private var inFlight = Set<String>()
}

struct LiveFrameResult: Sendable {
    struct Box: Sendable, Identifiable { let id: UUID; let rect: NormalizedBox; let label: String; let isFleet: Bool }
    var boxes: [Box]
    var hits: Int
}

/// The analysis context for one frame: the shared models plus the thorough text path only where the frame has
/// enough pixels to read lettering (docs/FEED-SOURCES.md §1 — recall collapses below ~480 px).
func frameContext(_ box: AnalysisContextBox, for buffer: CVPixelBuffer, readPlates: Bool, publicFeed: Bool = false) -> AnalysisContext {
    var context = box.current
    context.readPlates = readPlates
    context.suppressCameraCaptions = publicFeed
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
        
        let status = RTSPStreamStatus(url: url)
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

                            // The buffer is owned by this closure; wrap it here so a recorded
                            // hit can crop its evidence image without another cross-actor hop.
                            let source = EvidenceCrop.SourceFrame(pixelBuffer: packet.pixelBuffer)
                            await MainActor.run {
                                self.handleFrame(frame, timestamp: timestamp, source: source)
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
    
    private func handleFrame(_ frame: DetectionFrame, timestamp: Date, source: EvidenceCrop.SourceFrame? = nil) {
        guard !frame.vehicles.isEmpty else { return }
        
        var fleetHits = 0
        for vehicle in frame.vehicles {
            let (confidence, markings) = FleetScoring.vehicleGateScore(gate: gate, vehicle: vehicle)
            if gate.verdict(fleetConfidence: confidence) == .persistAndSync {
                fleetHits += 1
                if let context = modelContext {
                    let crop = source.flatMap { EvidenceCrop.make(source: $0, vehicle: vehicle, others: frame.vehicles) }
                    let dto = SightingSubmissionDTO(
                        capturedAt: timestamp,
                        geohash6: homeGeohash6,
                        cropHashSHA256: crop?.sha256Hex,
                        cropJPEGBase64: crop?.base64,
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

/// Only the selected web camera's latest frame is retained, in memory, while Live is visible.
struct WebFeedFrame {
    let image: CGImage
    let result: LiveFrameResult
    let updatedAt: Date
}
