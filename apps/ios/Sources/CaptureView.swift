import AVFoundation
import PlateKit
import PlateSync
import SwiftData
import SwiftUI
import UIKit

/// Live capture: camera preview with a detection overlay. Everything the
/// pipeline sees stays on-device unless the RedactionGate approves it.
struct CaptureView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncBackend) private var backend
    @StateObject private var viewModel = CaptureViewModel()
    @State private var permissionDenied = false

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
