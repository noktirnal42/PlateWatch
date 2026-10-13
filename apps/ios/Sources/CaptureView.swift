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

    var body: some View {
        ZStack {
            CameraPreview(session: viewModel.captureSession)
                .ignoresSafeArea()
            DetectionOverlay(frame: viewModel.latestFrame)
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
                CaptureControls(viewModel: viewModel, photoItem: $photoItem)
                    .padding(.bottom, 4)
                StatusBar(text: viewModel.statusText)
            }
            .padding()
            .animation(.snappy, value: viewModel.fleetHitPending)
        }
        .task {
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
            CaptureResultSheet(result: result)
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
            .disabled(viewModel.processingStill)
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
                    Section("Classification") {
                        LabeledContent("Vehicles in frame") { Text("\(result.vehicleCount)") }
                        LabeledContent("Fleet-approved") { Text("\(result.fleetCount)") }
                        LabeledContent("Top fleet confidence") {
                            Text("\(Int(result.topFleetConfidence * 100))%")
                        }
                        if result.watchlistHits > 0 {
                            LabeledContent("Watchlist hits") {
                                Text("\(result.watchlistHits)").foregroundStyle(PWStyle.fleet)
                            }
                        }
                    }
                    Section {
                        Text("Gate: only fleet-approved detections persist. \(result.source == "photo" ? "Imported photo" : "Live still") analyzed entirely on-device.")
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
        Label(text, systemImage: "record.circle")
            .font(.footnote.monospaced())
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
    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        private var videoLayer: AVCaptureVideoPreviewLayer? { layer as? AVCaptureVideoPreviewLayer }
        init(session: AVCaptureSession) {
            super.init(frame: .zero)
            videoLayer?.session = session
            videoLayer?.videoGravity = .resizeAspectFill
        }
        required init?(coder: NSCoder) { fatalError("storyboard-free") }
    }
}

/// Draws detections over the preview. Fleet vehicles get corner brackets
/// (a "targeting" look that reads as a classification, not a generic box);
/// everything else is a faint, dashed outline so it does not draw the eye.
/// Coordinates arrive in our NormalizedBox (top-left origin).
private struct DetectionOverlay: View {
    let frame: DetectionFrame?

    var body: some View {
        GeometryReader { geo in
            ForEach(frame?.vehicles ?? []) { vehicle in
                let box = vehicle.boundingBox
                let rect = CGRect(x: box.x * geo.size.width,
                                  y: box.y * geo.size.height,
                                  width: box.width * geo.size.width,
                                  height: box.height * geo.size.height)
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
                if let plate = vehicle.plates.first?.best {
                    PlateBadge(text: plate.text, compact: true)
                        .position(x: rect.midX, y: max(16, rect.minY - 14))
                }
            }
        }
        .allowsHitTesting(false)
        .animation(.easeOut(duration: 0.15), value: frame?.vehicles.count ?? 0)
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
