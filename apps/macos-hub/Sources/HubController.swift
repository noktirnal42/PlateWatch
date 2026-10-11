import CaptureKit
import Network
import PlateSync
import Foundation
import PlateKit
import SwiftData
import VehicleML

/// Fixed-camera ingest. v1 watches a folder that IP cameras FTP snapshots
/// into (every Reolink/Amcrest-class camera supports this) — zero SDKs, no
/// cloud accounts, cameras never touch the internet, which is on-mission.
/// v2: Bonjour-advertised HTTP snapshot endpoint for cameras/phones to POST
/// directly. RTSP ingest is roadmap M1 (see docs/ROADMAP.md).
@MainActor
final class HubController: ObservableObject {
    @Published private(set) var ingestFolder: URL
    @Published private(set) var framesAnalyzed = 0
    @Published private(set) var fleetHitsToday = 0
    @Published private(set) var pendingCount = 0
    @Published private(set) var snapshotServerStatus = "Stopped"
    @Published private(set) var snapshotPort: UInt16 = 0

    private let pipeline = PlateAnalysisPipeline()
    private let fileSource = FileFrameSource()
    private let gate = RedactionGate(config: .standard)
    private var watchDescriptor: DispatchSourceFileSystemObject?

    private var modelContext: ModelContext?
    /// Hub operator-set location bucket (these are fixed installations —
    /// the geohash-6 of the camera's own location).
    var homeGeohash6 = ""

    // Bonjour snapshot server
    private var snapshotListener: NWListener?
    private let snapshotQueue = DispatchQueue(label: "org.platewatch.hub.snapshot", qos: .userInitiated)
    private var bonjourRegistration: NetService?

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

    /// Start the Bonjour-advertised snapshot HTTP server.
    /// - Parameter port: Port to listen on (0 = auto-assign). Default 8088.
    func startSnapshotServer(port: UInt16 = 8088) async {
        guard snapshotListener == nil else { return }

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.includePeerToPeer = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
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
                        self?.snapshotServerStatus = "Failed: \(error.localizedDescription)"
                        self?.snapshotListener = nil
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

    func stopSnapshotServer() {
        snapshotListener?.cancel()
        snapshotListener = nil
        bonjourRegistration?.stop()
        bonjourRegistration = nil
        snapshotServerStatus = "Stopped"
        snapshotPort = 0
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
        receiveHTTPRequest(on: connection)
    }

    @MainActor
    private func receiveHTTPRequest(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, let data, !data.isEmpty else {
                if error != nil || isComplete { connection.cancel() }
                return
            }

            let requestString = String(decoding: data, as: UTF8.self)
            Task { @MainActor [weak self] in
                self?.parseAndHandleHTTPRequest(requestString, on: connection)
            }

            if !isComplete {
                Task { @MainActor [weak self] in
                    self?.receiveHTTPRequest(on: connection)
                }
            } else {
                connection.cancel()
            }
        }
    }

    @MainActor
    private func parseAndHandleHTTPRequest(_ request: String, on connection: NWConnection) {
        let lines = request.components(separatedBy: "\r\n")
        guard let firstLine = lines.first,
              firstLine.hasPrefix("POST /snapshot") else {
            sendHTTPResponse(on: connection, status: 404, body: "Not Found")
            return
        }

        // Find content length
        var contentLength = 0
        for line in lines {
            if line.lowercased().hasPrefix("content-length:") {
                let parts = line.split(separator: ":")
                if parts.count > 1, let len = Int(parts[1].trimmingCharacters(in: .whitespaces)) {
                    contentLength = len
                }
            }
        }

        // For simplicity, assume body is in the same buffer (small images)
        // In production, you'd accumulate until contentLength is reached
        let bodyStart = request.range(of: "\r\n\r\n")?.upperBound
        let body = bodyStart.map { String(request[$0...]) } ?? ""

        Task { @MainActor in
            await self.processSnapshotBody(body, contentLength: contentLength, on: connection)
        }
    }

    @MainActor
    private func processSnapshotBody(_ body: String, contentLength: Int, on connection: NWConnection) async {
        guard let data = body.data(using: .utf8),
              let buffer = FileFrameSource.pixelBuffer(from: data) else {
            sendHTTPResponse(on: connection, status: 400, body: "Invalid image data")
            return
        }

        do {
            let frame = try await pipeline.analyze(
                .init(pixelBuffer: buffer),
                context: AnalysisContext(models: [:]))
            framesAnalyzed += 1

            // frame is non-optional DetectionFrame; check if vehicles array is empty
            guard !frame.vehicles.isEmpty else {
                sendHTTPResponse(on: connection, status: 200, body: "OK (no vehicles)")
                return
            }

            var fleetHits = 0
            for vehicle in frame.vehicles {
                let markings = SceneTextHeuristics.parse(vehicle.sceneText)
                let confidence = gate.fleetConfidence(
                    vehicleClassifierFleet: vehicle.vehicleClass.isFleet ? vehicle.classConfidence : 0,
                    hasFleetMarkings: markings.hasFleetKeyword,
                    knownUnitMatch: false,
                    exemptPlateDesign: vehicle.plates.contains { $0.best?.exemptDesignHint == true })
                if gate.verdict(fleetConfidence: confidence) == .persistAndSync {
                    fleetHits += 1
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

            sendHTTPResponse(on: connection, status: 200, body: "OK (fleet hits: \(fleetHits))")
        } catch {
            sendHTTPResponse(on: connection, status: 500, body: "Processing error")
        }
    }

    private func sendHTTPResponse(on connection: NWConnection, status: Int, body: String) {
        let response = """
        HTTP/1.1 \(status) \(HTTPURLResponse.localizedString(forStatusCode: status))
        Content-Type: text/plain
        Content-Length: \(body.utf8.count)
        Connection: close

        \(body)
        """
        let data = response.data(using: .utf8)!
        connection.send(content: data, completion: .contentProcessed { _ in
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
