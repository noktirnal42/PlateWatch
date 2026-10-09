import AVFoundation
import Foundation

/// Live-camera frame source. Owns an AVCaptureSession configured for
/// plate-readable captures and forwards downsampled frames to one consumer.
///
/// Deliberately does no ML itself — inference lives in VehicleML stages.
public final class PlateCaptureSession: NSObject, @unchecked Sendable {

    public let configuration: CaptureConfiguration
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "org.openalpr.capture.frames", qos: .userInitiated)
    private var frameCounter: UInt64 = 0
    private var consumer: (@Sendable (FramePacket) -> Void)?

    public init(configuration: CaptureConfiguration = .handheld) {
        self.configuration = configuration
    }

    public var previewSession: AVCaptureSession { session }

    /// Configure the session. Call before `start()`. Throws on missing
    /// hardware/permissions-with-denial (permission *prompt* is the app's job).
    public func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = configuration.preset

        let device = try Self.selectDevice(preferTelephoto: configuration.preferTelephoto)
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else { throw CaptureError.cannotAddInput }
        session.addInput(input)

        videoOutput.alwaysDiscardsLateVideoFrames = true  // drop-oldest backpressure
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        guard session.canAddOutput(videoOutput) else { throw CaptureError.cannotAddOutput }
        session.addOutput(videoOutput)
        videoOutput.setSampleBufferDelegate(self, queue: outputQueue)

        try Self.tuneForPlates(device: device,
                               minShutter: configuration.minimumShutterSeconds)
    }

    public func onFrame(_ consumer: @escaping @Sendable (FramePacket) -> Void) {
        self.consumer = consumer
    }

    public func start() {
        if !session.isRunning { session.startRunning() }
    }

    public func stop() {
        if session.isRunning { session.stopRunning() }
    }

    public enum CaptureError: Error {
        case noSuitableCamera
        case cannotAddInput
        case cannotAddOutput
    }

    // MARK: - Device selection & tuning

    static func selectDevice(preferTelephoto: Bool) throws -> AVCaptureDevice {
        #if os(macOS)
        // macOS: built-in/Continuity/USB cameras — virtual iOS multi-cam types
        // don't exist here.
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera, .external],
            mediaType: .video, position: .unspecified)
        #else
        // Virtual multi-cam first: smooth zoom across physical lenses and the
        // best available reach on Pro devices.
        var candidates: [AVCaptureDevice.DeviceType] = [
            .builtInTripleCamera, .builtInDualWideCamera, .builtInDualCamera,
        ]
        if preferTelephoto { candidates.append(.builtInTelephotoCamera) }
        candidates.append(.builtInWideAngleCamera)
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: candidates, mediaType: .video, position: .back)
        #endif
        if let device = discovery.devices.first { return device }
        if let fallback = AVCaptureDevice.default(for: .video) { return fallback }
        throw CaptureError.noSuitableCamera
    }

    /// Shutter discipline: fast shutter beats high frame rate for ALPR.
    /// We set manual exposure (shutter floor + ISO ceiling) when supported.
    static func tuneForPlates(device: AVCaptureDevice, minShutter: Double) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        #if !os(macOS) // Manual exposure APIs are iOS-only on capture devices.
        if device.isExposureModeSupported(.custom) {
            let requested = CMTime(seconds: minShutter, preferredTimescale: 1_000_000)
            let minD = device.activeFormat.minExposureDuration
            let maxD = device.activeFormat.maxExposureDuration
            let shutter: CMTime
            if CMTimeCompare(requested, minD) < 0 { shutter = minD }
            else if CMTimeCompare(requested, maxD) > 0 { shutter = maxD }
            else { shutter = requested }
            device.setExposureModeCustom(duration: shutter, iso: device.activeFormat.minISO) { _ in }
            // NOTE: 1/500s+ is useless without enough light; the analyzer's
            // exposure-quality gate will drop unreadable frames instead of us
            // raising ISO into noise here.
        }
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
        device.automaticallyAdjustsVideoHDREnabled = false // HDR smears plates
        #endif
    }
}

extension PlateCaptureSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    public func captureOutput(_ output: AVCaptureOutput,
                              didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        frameCounter &+= 1
        let every = UInt64(max(1, configuration.analyzeEveryNthFrame))
        guard frameCounter % every == 0,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        consumer?(FramePacket(pixelBuffer: pixelBuffer,
                              timestamp: Date(),
                              sequenceNumber: frameCounter))
    }
}
