import AVFoundation
import PlateKit
import SwiftUI

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
                Spacer()
                HStack {
                    Label(viewModel.statusText, systemImage: "record.circle")
                        .font(.footnote.monospaced())
                        .padding(8)
                        .background(.ultraThinMaterial, in: .capsule)
                    Spacer()
                    if viewModel.fleetHitPending {
                        Image(systemName: "car.fill")
                            .symbolEffect(.pulse)
                            .foregroundStyle(.yellow)
                    }
                }
                .padding()
            }
        }
        .task {
            viewModel.attach(context: modelContext, backend: backend)
            await viewModel.start()
        }
        .onDisappear { viewModel.stop() }
        .alert("Camera access required", isPresented: $permissionDenied) {
            Button("Open Settings") { /* UIApplication.openSettings */ }
        } message: {
            Text("PlateWatch analyzes on-device; footage never uploads.")
        }
        .onChange(of: viewModel.permissionDenied) { _, value in permissionDenied = value }
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

/// Draws fleet-relevant boxes over the preview. Coordinates arrive in our
/// NormalizedBox (top-left origin).
private struct DetectionOverlay: View {
    let frame: DetectionFrame?

    var body: some View {
        GeometryReader { geo in
            ForEach(frame?.vehicles ?? []) { vehicle in
                let box = vehicle.boundingBox
                Rectangle()
                    .stroke(borderColor(for: vehicle), lineWidth: 2)
                    .frame(width: box.width * geo.size.width,
                           height: box.height * geo.size.height)
                    .position(x: (box.x + box.width / 2) * geo.size.width,
                              y: (box.y + box.height / 2) * geo.size.height)
                if let plate = vehicle.plates.first?.best {
                    Text(plate.text)
                        .font(.caption.monospaced())
                        .padding(4)
                        .background(.ultraThinMaterial)
                        .position(x: (box.x + box.width / 2) * geo.size.width,
                                  y: max(20, (box.y) * geo.size.height - 14))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func borderColor(for v: VehicleObservation) -> Color {
        v.vehicleClass.isFleet ? .yellow : .gray.opacity(0.4)
    }
}
