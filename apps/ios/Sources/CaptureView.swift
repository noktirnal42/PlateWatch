import AVFoundation
import PhotosUI
import PlateKit
import PlateSync
import SwiftData
import SwiftUI
import UIKit

/// Live capture: camera preview with a detection overlay. Everything the
/// pipeline sees stays on-device unless the RedactionGate approves it.
/// The shutter runs one accurate pass on the freshest frame; the photo
/// picker imports library images (the deterministic way to test detection).
struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncBackend) private var backend
    @StateObject private var viewModel = CaptureViewModel()
    @State private var permissionDenied = false
    @State private var photoItem: PhotosPickerItem?
    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            CameraPreview(session: viewModel.captureSession)
                .ignoresSafeArea().accessibilityHidden(true)
            DetectionOverlay(frame: viewModel.latestFrame)
                .ignoresSafeArea()
            if PreviewFixtures.isEnabled || (viewModel.cameraState != .running && viewModel.cameraState != .starting) {
                ScrollView {
                    CameraUnavailableCard(state: PreviewFixtures.isEnabled ? .unavailable("Preview") : viewModel.cameraState)
                        .padding(.horizontal, 24)
                }
                .safeAreaPadding(.top, 64)
                .safeAreaPadding(.bottom, 160)
            }
            VStack {
                HStack(alignment: .top) {
                    PrivacyChip()
                    Spacer()
                    if viewModel.fleetHitPending {
                        FleetHitChip()
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                }
                Spacer()
                if let clip = viewModel.latestEventClip {
                    HStack(spacing: 8) {
                        Label("Event buffer · \(clip.frameCount) frames · \(clip.duration, format: .number.precision(.fractionLength(1)))s", systemImage: "film.stack")
                            .accessibilityLabel("Fleet event buffer ready")
                            .accessibilityValue("\(clip.frameCount) frames, \(clip.duration, format: .number.precision(.fractionLength(1))) seconds")
                        if let url = viewModel.exportedEventClipURL {
                            ShareLink(item: url) { Image(systemName: "square.and.arrow.up") }
                                .accessibilityLabel("Share event clip")
                        } else {
                            Button {
                                Task { _ = await viewModel.exportLatestEventClip() }
                            } label: { Image(systemName: "arrow.down.to.line.compact") }
                                .accessibilityLabel("Save event clip")
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.62), in: Capsule())
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
                CaptureControls(viewModel: viewModel, photoItem: $photoItem)
                    .padding(.bottom, 4)
                StatusBar(text: PreviewFixtures.isEnabled
                          ? "Demo preview — camera and sync disabled"
                          : (viewModel.cameraState == .running && !viewModel.hasReceivedFrame
                             ? "Waiting for camera frames…"
                             : viewModel.statusText))
            }
            .padding()
            .animation(.snappy, value: viewModel.fleetHitPending)
        }
        .safeAreaInset(edge: .top) { PreviewBanner() }
        // Wait for onboarding: the camera prompt must not appear over it.
        .task(id: hasOnboarded) {
            guard !PreviewFixtures.isEnabled else { return }
            guard hasOnboarded else { return }
            viewModel.attach(context: modelContext, backend: backend)
            await viewModel.start()
        }
        .onDisappear { viewModel.stop() }
        .alert("Camera access required", isPresented: $permissionDenied) {
            Button("Open Settings") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            Button("Not now", role: .cancel) {}
        } message: {
            Text("PlateWatch analyzes on-device; footage never uploads.")
        }
        .onChange(of: viewModel.permissionDenied) { _, value in permissionDenied = value }
        .onChange(of: photoItem) { _, item in
            guard let item else { return }
            Task {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    await viewModel.processPhoto(data)
                } else {
                    viewModel.lastResult = .failed("photo", "Could not load that image.")
                }
                photoItem = nil
            }
        }
        .sheet(item: $viewModel.lastResult) { result in
            CaptureResultSheet(result: result, onConfirm: { viewModel.confirm($0) },
                               onChooseState: { viewModel.chooseState($0, $1) })
                .presentationDetents([.medium, .large])
        }
    }
}

/// Shutter + photo import + processing indicator, floating above the status.
private struct CaptureControls: View {
    @ObservedObject var viewModel: CaptureViewModel
    @Binding var photoItem: PhotosPickerItem?

    var body: some View {
        HStack(spacing: 28) {
            PhotosPicker(selection: $photoItem, matching: .images) {
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: .circle)
            }
            .accessibilityLabel("Import a photo to analyze")

            Button {
                Task { await viewModel.captureStill() }
            } label: {
                ZStack {
                    Circle()
                        .stroke(.white, lineWidth: 4)
                        .frame(width: 72, height: 72)
                    Circle()
                        .fill(viewModel.processingStill ? AnyShapeStyle(.gray) : AnyShapeStyle(PWStyle.fleet))
                        .frame(width: 58, height: 58)
                    if viewModel.processingStill {
                        ProgressView().tint(.black)
                    }
                }
            }
            .disabled(viewModel.processingStill || viewModel.cameraState != .running)
            .accessibilityLabel("Capture still frame")
            .accessibilityHint("Runs one accurate analysis pass on the current frame")

            Image(systemName: "record.circle")
                .font(.title2)
                .foregroundStyle(viewModel.fleetHitPending ? PWStyle.fleet : .white.opacity(0.35))
                .frame(width: 52, height: 52)
                .accessibilityHidden(true)
        }
    }
}

/// Post-capture report: what the pipeline actually saw. This is the QA
/// surface — a police-car photo either shows plates here or it didn't read.
private struct CaptureResultSheet: View {
    let result: CaptureResult
    let onConfirm: (UUID) -> Void
    var onChooseState: ((UUID, String) -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                if let error = result.error {
                    Section {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(PWStyle.failing)
                    }
                } else {
                    Section("Read plates") {
                        if result.plates.isEmpty {
                            Text("None — no text matched plate geometry or patterns.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(result.plates, id: \.self) { plate in
                                PlateBadge(text: String(plate.prefix { $0 != " " }))
                                Text(plate)
                                    .font(.footnote.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    if !result.candidates.isEmpty {
                        Section {
                            ForEach(result.candidates) { candidate in
                                VStack(alignment: .leading, spacing: 10) {
                                    Label(candidate.summary, systemImage: "questionmark.circle.fill")
                                        .font(.subheadline.weight(.semibold))
                                    if let identity = candidate.identity, !identity.isEmpty {
                                        IdentityCard(identity: identity,
                                                     onChooseState: candidate.confirmed ? nil : { onChooseState?(candidate.id, $0) })
                                    }
                                    if candidate.confirmed {
                                        Label("Sent for moderator review", systemImage: "checkmark.circle.fill")
                                            .foregroundStyle(PWStyle.synced)
                                    } else {
                                        Button {
                                            onConfirm(candidate.id)
                                        } label: {
                                            Text("This is a government vehicle — record it")
                                                .frame(maxWidth: .infinity)
                                        }
                                        .buttonStyle(.borderedProminent)
                                        .tint(PWStyle.fleet)
                                        .foregroundStyle(.black)
                                    }
                                }
                                .padding(.vertical, 4)
                            }
                        } header: {
                            Text("Possible fleet vehicle")
                        } footer: {
                            Text("PlateWatch saw fleet evidence but not enough to record on its own. If you can see it is a public-service vehicle, confirm it. Confirmed sightings go to moderator review first — nothing is published on your word alone.")
                        }
                    }
                    if result.candidates.isEmpty, let identity = result.identity, !identity.isEmpty {
                        Section("Identification") { IdentityCard(identity: identity) }
                    }
                    Section("Fleet markings found") {
                        if result.markings.isEmpty {
                            Text("No agency, service or unit text was read.")
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(result.markings, id: \.self) { Text($0) }
                        }
                    }
                    Section("Classification") {
                        LabeledContent("Vehicles in frame") { Text("\(result.vehicleCount)") }
                        LabeledContent("Fleet confidence") {
                            Text("\(Int(result.topFleetConfidence * 100))% of \(Int(result.approvalThreshold * 100))% needed")
                        }
                        LabeledContent("Recorded") {
                            Text(result.fleetCount > 0 ? "Yes · queued to sync" : "No")
                                .foregroundStyle(result.fleetCount > 0 ? PWStyle.synced : .secondary)
                        }
                        if result.watchlistHits > 0 {
                            LabeledContent("Watchlist hits") {
                                Text("\(result.watchlistHits)").foregroundStyle(PWStyle.fleet)
                            }
                        }
                    }
                    Section {
                        Text(result.fleetCount > 0
                             ? "This detection cleared the fleet gate, so it was queued for sync. Analysis ran entirely on this device."
                             : "Only detections that clear the fleet gate are kept. A bare “POLICE” decal is not enough — the gate needs agency text and a unit number, or a fleet classifier, to be confident it is a public vehicle.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Analysis (\(result.source))")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Monospaced capture status in a quiet material bar.
private struct StatusBar: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "viewfinder")
            .font(.footnote.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.ultraThinMaterial, in: .capsule)
            .accessibilityLabel("Capture status: \(text)")
    }
}

/// Shown while a fleet-classified detection is being confirmed.
private struct FleetHitChip: View {
    var body: some View {
        Label("Fleet vehicle", systemImage: "car.fill")
            .font(.footnote.weight(.semibold))
            .symbolEffect(.pulse)
            .foregroundStyle(.black)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(PWStyle.fleet, in: .capsule)
            .accessibilityLabel("Fleet vehicle detected")
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView { PreviewView(session: session) }
    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.updateVideoOrientation()
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var videoLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            videoLayer?.session = session
            videoLayer?.videoGravity = .resizeAspectFill
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            updateVideoOrientation()
        }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            updateVideoOrientation()
        }
        /// Keep the preview layer's sensor rotation in step with the rotated
        /// sample buffers delivered by CaptureKit. Without this, the live
        /// image rotates independently of the controls and detection overlay.
        func updateVideoOrientation() {
            guard let connection = videoLayer?.connection,
                  let orientation = window?.windowScene?.interfaceOrientation else { return }
            let angle: CGFloat
            switch orientation {
            case .portrait: angle = 90
            case .portraitUpsideDown: angle = 270
            case .landscapeLeft: angle = 180
            case .landscapeRight: angle = 0
            default: return
            }
            guard connection.isVideoRotationAngleSupported(angle) else { return }
            connection.videoRotationAngle = angle
        }
        required init?(coder: NSCoder) { fatalError("storyboard-free") }
    }
}

/// Draws every detected vehicle over the preview. Fleet vehicles get corner
/// brackets; ordinary vehicles get a quieter outline, while both retain a
/// readable body-class label so the phone view matches Hub Live.
/// Coordinates arrive in our NormalizedBox (top-left origin).
private struct DetectionOverlay: View {
    let frame: DetectionFrame?

    /// Maps a normalized box (top-left origin, relative to the analyzed
    /// image) into view space, accounting for the preview's aspect-fill crop.
    private func rect(for box: NormalizedBox, image: CGSize, in view: CGSize) -> CGRect {
        guard image.width > 0, image.height > 0 else { return .zero }
        let scale = max(view.width / image.width, view.height / image.height)
        let shown = CGSize(width: image.width * scale, height: image.height * scale)
        let origin = CGPoint(x: (view.width - shown.width) / 2, y: (view.height - shown.height) / 2)
        return CGRect(x: origin.x + box.x * shown.width, y: origin.y + box.y * shown.height,
                      width: box.width * shown.width, height: box.height * shown.height)
    }

    var body: some View {
        GeometryReader { geo in
            ForEach(frame?.vehicles ?? []) { vehicle in
                let rect = rect(for: vehicle.boundingBox, image: frame?.imageSize ?? .zero, in: geo.size)
                if vehicle.vehicleClass.isFleet {
                    CornerBrackets()
                        .stroke(PWStyle.fleet, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                } else {
                    Rectangle()
                        .stroke(.white.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .frame(width: rect.width, height: rect.height)
                        .position(x: rect.midX, y: rect.midY)
                }
                if rect.width >= 58, rect.height >= 34 {
                    Text(IOSVehicleOverlayLabel.text(for: vehicle))
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .foregroundStyle(.black)
                        .background(vehicle.vehicleClass.isFleet ? PWStyle.fleet : .white.opacity(0.86), in: Capsule())
                        .position(x: min(max(rect.midX, 52), geo.size.width - 52),
                                  y: max(12, rect.minY + 12))
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Vehicle detections")
        .accessibilityValue(accessibilitySummary)
        .accessibilityIdentifier("vehicle-detections")
        .animation(.easeOut(duration: 0.15), value: frame?.vehicles.count ?? 0)
    }

    private var accessibilitySummary: String {
        let vehicles = frame?.vehicles ?? []
        let fleetCount = vehicles.filter { $0.vehicleClass.isFleet }.count
        guard !vehicles.isEmpty else { return "No vehicles detected" }
        let labels = vehicles.enumerated().map { index, vehicle in
            "Vehicle \(index + 1): \(IOSVehicleOverlayLabel.text(for: vehicle))"
        }
        return "\(vehicles.count) vehicles in view; \(fleetCount) fleet vehicles. " + labels.joined(separator: ". ")
    }
}

private enum IOSVehicleOverlayLabel {
    static func text(for vehicle: VehicleObservation) -> String {
        let body = vehicle.attributes?.bodyType.flatMap { value -> String? in
            switch value.lowercased().replacingOccurrences(of: "_", with: " ") {
            case "car", "automobile", "sedan", "coupe", "hatchback": return "Car"
            case "truck", "lorry": return "Truck"
            case "bus", "coach": return "Bus"
            case "motorcycle", "motorbike": return "Motorcycle"
            case "suv", "sport utility vehicle", "sport utility": return "SUV"
            case "van", "minivan": return "Van"
            case "pickup", "pickup truck": return "Pickup"
            default: return nil
            }
        }
        let color = vehicle.attributes?.color.flatMap { value -> String? in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst().lowercased()
        }
        let vehicleLabel = [color, body].compactMap { $0 }.joined(separator: " ")
        guard vehicle.vehicleClass.isFleet else {
            guard vehicle.classConfidence.isFinite, vehicle.classConfidence > 0 else {
                return vehicleLabel.isEmpty ? "Vehicle" : vehicleLabel
            }
            let score = Int(min(1, max(0, vehicle.classConfidence)) * 100)
            return "\(vehicleLabel.isEmpty ? "Vehicle" : vehicleLabel) · class \(score)%"
        }
        let fleet = switch vehicle.vehicleClass {
        case .patrol: "Patrol"
        case .fireEngine: "Fire engine"
        case .ambulance: "Ambulance"
        case .publicWorks: "Public works"
        case .transit: "Transit"
        case .schoolBus: "School bus"
        case .federal: "Federal"
        case .military: "Military"
        case .parkRanger: "Park ranger"
        case .highway: "Highway"
        default: "Fleet"
        }
        let fleetLabel = [color, body ?? "Vehicle"].compactMap { $0 }.joined(separator: " ")
        return [fleetLabel, fleet].joined(separator: " · ")
    }
}

/// Shown instead of a black screen when there is no live camera (simulator,
/// Mac mirroring, permission off). The photo import button stays usable.
private struct CameraUnavailableCard: View {
    let state: CaptureViewModel.CameraState

    var body: some View {
        VStack(spacing: 14) {
            PWEmptyState(
                title: state == .denied ? "Camera is off" : "No live camera",
                message: state == .denied
                    ? "Allow camera access in Settings to scan, or import a photo to analyze it on this device."
                    : "This device can’t provide a camera feed right now. Import a photo of a vehicle to try the analyzer.",
                systemImage: state == .denied ? "camera.fill" : "photo.on.rectangle")
            if state == .denied {
                Button("Open Settings") {
                    if let url = URL(string: UIApplication.openSettingsURLString) {
                        UIApplication.shared.open(url)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(PWStyle.fleet)
                .foregroundStyle(.black)
            }
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .background(.black.opacity(0.35), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

/// Four L-shaped corners inset into the rect.
private struct CornerBrackets: Shape {
    func path(in rect: CGRect) -> Path {
        let len = min(rect.width, rect.height) * 0.22
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY + len))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.minX + len, y: rect.minY))
        p.move(to: CGPoint(x: rect.maxX - len, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + len))
        p.move(to: CGPoint(x: rect.maxX, y: rect.maxY - len))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.maxX - len, y: rect.maxY))
        p.move(to: CGPoint(x: rect.minX + len, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - len))
        return p
    }
}
