import AVFoundation
import CoreImage
import PlateKit
import SwiftUI

/// Live viewer: a local camera (including an iPhone over Continuity Camera) or a video file, analysed on-device at a
/// low rate. Frames live in memory only; nothing is recorded except fleet hits through the normal gate.
@MainActor
final class LiveController: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published private(set) var image: CGImage?
    @Published private(set) var boxes: [LiveFrameResult.Box] = []
    @Published private(set) var status = "Idle"
    @Published private(set) var running = false
    @Published private(set) var hits = 0
    @Published private(set) var pausedVideo = false
    private var videoURL: URL?
    private var videoSecond = 0.0
    private var generation = UUID()

    private let hub: HubController
    private var session: AVCaptureSession?
    private var loop: Task<Void, Never>?
    private let latest = LatestFrame()
    private let ciContext = CIContext()
    private let sampleQueue = DispatchQueue(label: "org.platewatch.hub.live", qos: .userInitiated)

    init(hub: HubController) { self.hub = hub }

    func startCamera(_ device: AVCaptureDevice) async {
        stop()
        videoURL = nil; videoSecond = 0
        guard await AVCaptureDevice.requestAccess(for: .video) else { status = "Camera access denied (System Settings › Privacy)"; return }
        let session = AVCaptureSession()
        guard let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { status = "Cannot open \(device.localizedName)"; return }
        session.addInput(input)
        let output = AVCaptureVideoDataOutput()
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: sampleQueue)
        guard session.canAddOutput(output) else { status = "Cannot read frames"; return }
        session.addOutput(output)
        self.session = session
        let box = latest
        nonisolated(unsafe) let running = session
        sampleQueue.async { running.startRunning() }
        begin("Camera: \(device.localizedName)", sourceID: "local-\(device.uniqueID)") { box.take() }
    }

    func startVideo(_ url: URL, resume: Bool = false) {
        let offset = resume ? videoSecond : 0
        stop()
        videoURL = url
        pausedVideo = false
        let run = generation
        let box = latest
        loop = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var second = offset
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            guard !Task.isCancelled, self?.generation == run else { return }
            await MainActor.run { self?.running = true; self?.status = "Video: \(url.lastPathComponent)" }
            while !Task.isCancelled, second < duration {
                if let cg = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image {
                    guard !Task.isCancelled, self?.generation == run else { return }
                    box.put(cg)
                    await self?.process(sourceID: "video-\(url.lastPathComponent)") { box.take() }
                }
                guard !Task.isCancelled, self?.generation == run else { return }
                second += 1
                self?.videoSecond = second
                do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            }
            guard !Task.isCancelled, self?.generation == run else { return }
            await MainActor.run { self?.running = false; self?.status = "Finished \(url.lastPathComponent)" }
        }
    }

    func pause() {
        guard running else { return }
        let canResume = videoURL != nil
        stop()
        pausedVideo = canResume
        status = "Paused while away from Live"
    }

    func resumeVideo() {
        guard let videoURL else { return }
        startVideo(videoURL, resume: true)
    }

    func stop() {
        generation = UUID()
        pausedVideo = false
        loop?.cancel(); loop = nil
        session?.stopRunning(); session = nil
        running = false
        status = "Idle"
    }

    private func begin(_ label: String, sourceID: String, next: @escaping @Sendable () -> CGImage?) {
        running = true; status = label
        loop = Task { [weak self] in
            while !Task.isCancelled {
                await self?.process(sourceID: sourceID, next: next)
                try? await Task.sleep(for: .milliseconds(700))     // ~1.4 analysed frames/s; cheap and polite to the CPU
            }
        }
    }

    private func process(sourceID: String, next: @Sendable () -> CGImage?) async {
        let run = generation
        guard !Task.isCancelled, let cg = next(), let buffer = Self.pixelBuffer(from: cg) else { return }
        image = cg
        if let result = await hub.analyseLive(buffer, sourceID: sourceID) {
            guard !Task.isCancelled, generation == run else { return }
            boxes = result.boxes
            hits += result.hits
        }
    }

    nonisolated func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let ci = CIImage(cvPixelBuffer: pixels)
        if let cg = CIContext().createCGImage(ci, from: ci.extent) { latest.put(cg) }
    }

    static func pixelBuffer(from image: CGImage) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, image.width, image.height, kCVPixelFormatType_32BGRA, attrs, &buffer) == kCVReturnSuccess,
              let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: image.width, height: image.height,
                                      bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return buffer
    }
}

/// Newest frame handed from the capture queue to the analysis loop; older frames are dropped.
final class LatestFrame: @unchecked Sendable {
    private let lock = NSLock()
    private var frame: CGImage?
    func put(_ image: CGImage) { lock.lock(); frame = image; lock.unlock() }
    func take() -> CGImage? { lock.lock(); defer { lock.unlock() }; let f = frame; frame = nil; return f }
}

struct LivePane: View {
    @ObservedObject private var hub: HubController
    @ObservedObject private var runner: FeedRunner
    @StateObject private var live: LiveController
    let isActive: Bool
    @State private var devices: [AVCaptureDevice] = []
    @AppStorage("liveSelectedCamera") private var selected: String = ""
    @AppStorage("hubShowDetectionOverlays") private var showOverlays = true

    init(hub: HubController, isActive: Bool = true) { self.hub = hub; self.runner = hub.feedRunner; self.isActive = isActive; _live = StateObject(wrappedValue: LiveController(hub: hub)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let source = hub.liveFeed {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(source.name, systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                        Text("\(source.kind == .snapshotJPEG ? "Snapshot feed" : "Video feed") · \(hub.liveFeedStatus)").font(.caption).foregroundStyle(.secondary)
                        if source.kind == .snapshotJPEG, let received = runner.lastReceivedAt[source.id] {
                            SnapshotFreshnessLabel(received: received, changed: runner.contentChangedAt[source.id] ?? received,
                                                   interval: source.refreshInterval)
                        }
                        if let frame = hub.liveFeedFrame {
                            Text("Analysed \(frame.updatedAt, format: .dateTime.hour().minute().second()) · \(frame.result.boxes.count) vehicle(s)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    FeedBlockButton(hub: hub, preferences: hub.favorites, source: source)
                    Button("Close web feed") { hub.stopLiveFeed() }
                }
            }
            HStack {
                Picker("Camera", selection: $selected) {
                    ForEach(devices, id: \.uniqueID) { Text($0.localizedName).tag($0.uniqueID) }
                }.frame(maxWidth: 320)
                Button("Start camera") {
                    if let d = devices.first(where: { $0.uniqueID == selected }) { hub.stopLiveFeed(); Task { await live.startCamera(d) } }
                }.disabled(selected.isEmpty)
                Button("Open video…") {
                    let panel = NSOpenPanel(); panel.allowedContentTypes = [.movie, .video]
                    if panel.runModal() == .OK, let url = panel.url { hub.stopLiveFeed(); live.startVideo(url) }
                }
                if live.pausedVideo { Button("Resume video") { hub.stopLiveFeed(); live.resumeVideo() } }
                Button("Stop") { live.stop(); hub.stopLiveFeed() }.disabled(!live.running && hub.liveFeed == nil)
                Spacer()
                Toggle("Overlays", isOn: $showOverlays).toggleStyle(.checkbox)
                    .help("Show car, truck, bus and motorcycle boxes; fleet labels include a fleet score. Small boxes show their label on hover.")
                if hub.liveFeed == nil {
                    Text("\(live.status) · \(live.hits) fleet hit(s)").font(.caption).foregroundStyle(.secondary)
                }
            }
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let image = hub.liveFeed == nil ? live.image : hub.liveFeedFrame?.image {
                    GeometryReader { geo in
                        let size = fitted(CGSize(width: image.width, height: image.height), in: geo.size)
                        ZStack(alignment: .topLeading) {
                            Image(decorative: image, scale: 1).resizable().frame(width: size.width, height: size.height)
                            ForEach(showOverlays ? (hub.liveFeed == nil ? live.boxes : (hub.liveFeedFrame?.result.boxes ?? [])) : []) { box in
                                Rectangle().stroke(box.isFleet ? Color.green : Color.yellow, lineWidth: 2)
                                    .frame(width: box.rect.width * size.width, height: box.rect.height * size.height)
                                    .overlay(alignment: .topLeading) {
                                        if box.rect.width * size.width >= 72 {
                                            Text(box.label).font(.system(size: 11, weight: .semibold, design: .rounded))
                                                .fixedSize().padding(.horizontal, 6).padding(.vertical, 3)
                                                .background(box.isFleet ? Color.green : Color.yellow, in: RoundedRectangle(cornerRadius: 4))
                                                .foregroundStyle(.black)
                                                .offset(y: box.rect.y * size.height > 24 ? -24 : 2)
                                        }
                                    }
                                    .help(box.label)
                                    .accessibilityLabel(box.label)
                                    .offset(x: box.rect.x * size.width, y: box.rect.y * size.height)
                            }
                        }
                        .frame(width: size.width, height: size.height)
                        .position(x: geo.size.width / 2, y: geo.size.height / 2)
                    }
                } else {
                    Text(hub.liveFeed == nil ? "Start a camera, open a video, or choose Open in Live in Public feeds" : hub.liveFeedStatus).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            Text("In memory only. Overlays show general vehicle classes; fleet labels include a fleet score. Plate text is never shown. Fleet hits pass the same redaction gate and jurisdiction rules as every other source.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified).devices
            if selected.isEmpty { selected = devices.first?.uniqueID ?? "" }
        }
        .task(id: "\(isActive)-\(hub.liveFeed?.id.uuidString ?? "local")") {
            if isActive, hub.liveFeed != nil { live.stop(); await hub.loadLiveFeed() }
        }
        .onChange(of: isActive) { _, active in if !active { live.pause() } }
        .onDisappear { live.stop() }
    }

    private func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}

private struct SnapshotFreshnessLabel: View {
    let received: Date
    let changed: Date
    let interval: TimeInterval
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { tick in
            let warning = tick.date.timeIntervalSince(changed) > max(600, interval * 2)
            Group {
                if warning {
                    Text("Received \(received, format: .dateTime.hour().minute().second()) · image unchanged since \(changed, format: .dateTime.hour().minute())")
                } else {
                    Text("Received \(received, format: .dateTime.hour().minute().second())")
                }
            }
            .font(.caption).foregroundStyle(warning ? Color.orange : Color.secondary)
            .help("Receiving an image proves delivery, not camera freshness. Identical image bytes may indicate a static scene or an upstream freeze.")
        }
    }
}
