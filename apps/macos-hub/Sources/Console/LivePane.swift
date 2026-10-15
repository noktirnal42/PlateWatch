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

    private let hub: HubController
    private var session: AVCaptureSession?
    private var loop: Task<Void, Never>?
    private let latest = LatestFrame()
    private let ciContext = CIContext()
    private let sampleQueue = DispatchQueue(label: "org.platewatch.hub.live", qos: .userInitiated)

    init(hub: HubController) { self.hub = hub }

    func startCamera(_ device: AVCaptureDevice) async {
        stop()
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

    func startVideo(_ url: URL) {
        stop()
        let box = latest
        loop = Task { [weak self] in
            let asset = AVURLAsset(url: url)
            let generator = AVAssetImageGenerator(asset: asset)
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            var second = 0.0
            let duration = (try? await asset.load(.duration).seconds) ?? 0
            await MainActor.run { self?.running = true; self?.status = "Video: \(url.lastPathComponent)" }
            while !Task.isCancelled, second < duration {
                if let cg = try? await generator.image(at: CMTime(seconds: second, preferredTimescale: 600)).image {
                    box.put(cg)
                    await self?.process(sourceID: "video-\(url.lastPathComponent)") { box.take() }
                }
                second += 1
            }
            await MainActor.run { self?.running = false; self?.status = "Finished \(url.lastPathComponent)" }
        }
    }

    func stop() {
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
        guard let cg = next(), let buffer = Self.pixelBuffer(from: cg) else { return }
        image = cg
        if let result = await hub.analyseLive(buffer, sourceID: sourceID) {
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
    @StateObject private var live: LiveController
    @State private var devices: [AVCaptureDevice] = []
    @State private var selected: String = ""

    init(hub: HubController) { self.hub = hub; _live = StateObject(wrappedValue: LiveController(hub: hub)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let source = hub.liveFeed {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Label(source.name, systemImage: "antenna.radiowaves.left.and.right").font(.headline)
                        Text("Snapshot feed · \(hub.liveFeedStatus)").font(.caption).foregroundStyle(.secondary)
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
                Button("Stop") { live.stop(); hub.stopLiveFeed() }.disabled(!live.running && hub.liveFeed == nil)
                Spacer()
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
                            ForEach(hub.liveFeed == nil ? live.boxes : (hub.liveFeedFrame?.result.boxes ?? [])) { box in
                                Rectangle().stroke(box.isFleet ? Color.green : Color.yellow, lineWidth: 2)
                                    .frame(width: box.rect.width * size.width, height: box.rect.height * size.height)
                                    .overlay(alignment: .topLeading) {
                                        Text(box.label).font(.caption2.bold()).padding(2)
                                            .background(box.isFleet ? Color.green : Color.yellow).foregroundStyle(.black)
                                            .offset(y: -16)
                                    }
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
            Text("In memory only. Overlays show vehicle class and fleet score, never plate text. Fleet hits pass the same redaction gate and jurisdiction rules as every other source.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear {
            devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified).devices
            if selected.isEmpty { selected = devices.first?.uniqueID ?? "" }
        }
        .task(id: hub.liveFeed?.id) {
            if hub.liveFeed != nil { live.stop(); await hub.loadLiveFeed() }
        }
        .onDisappear { live.stop(); hub.stopLiveFeed() }
    }

    private func fitted(_ image: CGSize, in box: CGSize) -> CGSize {
        let scale = min(box.width / image.width, box.height / image.height)
        return CGSize(width: image.width * scale, height: image.height * scale)
    }
}
