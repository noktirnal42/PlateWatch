@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Live-camera frame source. Owns an AVCaptureSession configured for
/// plate-readable captures and forwards downsampled frames to one consumer.
///
/// Deliberately does no ML itself — inference lives in VehicleML stages.
public final class PlateCaptureSession: NSObject, @unchecked Sendable {

    public let configuration: CaptureConfiguration
    private let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let outputQueue = DispatchQueue(label: "org.platewatch.capture.frames", qos: .userInitiated)
    private var frameCounter: UInt64 = 0
    private var consumer: (@Sendable (FramePacket) -> Void)?
    private var eventClipConsumer: (@Sendable (EventClip) -> Void)?
    private let rollingBuffer: FrameRollingBuffer
    private var lastExposureDuration: CMTime?
    private var lastISO: Float?
    private var activeDevice: AVCaptureDevice?
    #if os(iOS)
    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    #endif

    public init(configuration: CaptureConfiguration = .handheld) {
        self.configuration = configuration
        let fps = 30.0
        let totalSeconds = configuration.eventClipPreRollSeconds + configuration.eventClipPostRollSeconds
        let maxFrames = Int(totalSeconds * fps * 1.5) // 1.5x headroom
        self.rollingBuffer = FrameRollingBuffer(maxFrames: maxFrames)
    }

    public var previewSession: AVCaptureSession { session }

    /// Configure the session. Call before `start()`. Throws on missing
    /// hardware/permissions-with-denial (permission *prompt* is the app's job).
    /// Idempotent: safe to call again after a tab switch — existing inputs/
    /// outputs are replaced rather than stacked (stacking made every second
    /// configure() fail with `cannotAddInput`).
    public func configure() throws {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = configuration.preset

        for existing in session.inputs { session.removeInput(existing) }
        for existing in session.outputs { session.removeOutput(existing) }

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
        activeDevice = device
        installRotation(for: device)

        try Self.tuneForPlates(device: device,
                               minShutter: configuration.minimumShutterSeconds,
                               maxISO: configuration.maximumISO)
    }

    /// Deliver upright frames. A phone camera sensor is landscape; without a
    /// rotation on the output connection, Vision sees sideways text and the
    /// detection overlay no longer lines up with the preview. The rotation
    /// coordinator tracks gravity, so portrait/landscape both work.
    private func installRotation(for device: AVCaptureDevice) {
        #if os(iOS)
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: nil)
        rotationCoordinator = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelCapture)
        rotationObservation = coordinator.observe(
            \.videoRotationAngleForHorizonLevelCapture, options: [.new]) { [weak self] _, change in
            if let angle = change.newValue { self?.applyRotation(angle) }
        }
        #endif
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = videoOutput.connection(with: .video),
              connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }

    public func onFrame(_ consumer: @escaping @Sendable (FramePacket) -> Void) {
        self.consumer = consumer
    }

    /// Called when a fleet-classified event is detected to extract the event clip.
    public func onFleetEvent(_ consumer: @escaping @Sendable (EventClip) -> Void) {
        self.eventClipConsumer = consumer
    }

    private let lifecycleQueue = DispatchQueue(label: "org.platewatch.capture.lifecycle", qos: .userInitiated)

    public func start() {
        // startRunning() blocks for tens/hundreds of ms — never the main thread.
        lifecycleQueue.async { [session] in
            if !session.isRunning { session.startRunning() }
        }
    }

    public func stop() {
        lifecycleQueue.async { [session] in
            if session.isRunning { session.stopRunning() }
        }
    }

    public enum CaptureError: Error, LocalizedError {
        case noSuitableCamera
        case cannotAddInput
        case cannotAddOutput

        public var errorDescription: String? {
            switch self {
            case .noSuitableCamera: return "No camera is available on this device."
            case .cannotAddInput, .cannotAddOutput: return "The camera could not be started."
            }
        }
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

    /// Shutter discipline: a fast shutter beats high frame rate for ALPR, but
    /// pinning a manual shutter + ISO crushes dim scenes to black. Instead we
    /// keep continuous auto-exposure and cap the *longest* shutter the
    /// auto-exposure may choose, so it raises ISO to compensate and only
    /// falls back to a slower shutter at the device's own limits.
    static func tuneForPlates(device: AVCaptureDevice, minShutter: Double, maxISO: Float) throws {
        try device.lockForConfiguration()
        defer { device.unlockForConfiguration() }

        #if !os(macOS)
        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        }
        let requested = CMTime(seconds: minShutter, preferredTimescale: 1_000_000)
        let floor = device.activeFormat.minExposureDuration
        let cap = CMTimeCompare(requested, floor) < 0 ? floor : requested
        device.activeMaxExposureDuration = cap
        device.automaticallyAdjustsVideoHDREnabled = false // HDR smears plates
        if device.activeFormat.isVideoHDRSupported { device.isVideoHDREnabled = false }
        #endif
        if device.isFocusModeSupported(.continuousAutoFocus) {
            device.focusMode = .continuousAutoFocus
        }
    }

    /// Extracts an event clip around the trigger frame's absolute index.
    /// The buffer only retains analyzed frames (and drops the oldest under
    /// pressure), so the trigger frame itself may be missing — the clip is
    /// then anchored to the closest retained frame at-or-before the trigger.
    public func extractEventClip(triggerFrameIndex: Int) -> EventClip? {
        let preFrames = Int(configuration.eventClipPreRollSeconds * 30.0)
        let postFrames = Int(configuration.eventClipPostRollSeconds * 30.0)
        let start = max(0, triggerFrameIndex - preFrames)
        let end = triggerFrameIndex + postFrames
        let frames = rollingBuffer.extractClip(from: start, to: end)
        guard let triggerPosition: Int = {
            if let exact = frames.firstIndex(where: { Int($0.sequenceNumber) == triggerFrameIndex }) {
                return exact
            }
            return frames.lastIndex(where: { Int($0.sequenceNumber) < triggerFrameIndex })
        }() else { return nil }
        return EventClip(
            frames: frames,
            triggerFrameIndex: triggerPosition,
            triggerTimestamp: frames[triggerPosition].timestamp
        )
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

        let (exposureDuration, iso) = currentExposure()

        let packet = FramePacket(
            pixelBuffer: pixelBuffer,
            timestamp: Date(),
            sequenceNumber: frameCounter,
            exposureDuration: exposureDuration,
            iso: iso
        )

        rollingBuffer.append(packet)
        consumer?(packet)

    }

    /// Live exposure straight from the device (the sample-buffer attachment
    /// keys the old code read are not a public API and came back nil).
    private func currentExposure() -> (CMTime?, Float?) {
        #if os(iOS)
        guard let device = activeDevice else { return (nil, nil) }
        return (device.exposureDuration, device.iso)
        #else
        return (nil, nil)
        #endif
    }
}

/// Adaptive exposure controller that maintains minimum shutter while bounding ISO.
final class AdaptiveExposureController {
    private let minShutter: Double
    private let maxISO: Float
    private var lastMeasuredShutter: Double = 0
    private var lastMeasuredISO: Float = 0
    private let targetExposureValue: Double = -4.0 // Target EV for plate reading
    private var frameCount = 0

    init(minShutter: Double, maxISO: Float) {
        self.minShutter = minShutter
        self.maxISO = maxISO
    }

    /// Returns suggested (shutter, iso) if adjustment needed, nil if stable.
    func update(measuredShutter: Double, measuredISO: Float) -> (CMTime, Float)? {
        lastMeasuredShutter = measuredShutter
        lastMeasuredISO = measuredISO
        frameCount += 1

        // Only adjust every 10 frames to avoid oscillation
        guard frameCount % 10 == 0 else { return nil }

        // If shutter is SLOWER than minimum (larger duration), try to increase ISO (if headroom)
        if measuredShutter > minShutter {
            if measuredISO < maxISO * 0.8 { // 20% headroom
                let newISO = min(measuredISO * 1.2, maxISO)
                return (CMTime(seconds: minShutter, preferredTimescale: 1_000_000), newISO)
            }
        }

        // If ISO is at ceiling and shutter still slow, accept it (low light)
        if measuredISO >= maxISO * 0.95 && measuredShutter > minShutter {
            return nil // Can't improve, let analyzer handle it
        }

        // If we have excess light (fast shutter + low ISO), we can relax
        // Fast shutter = SMALLER duration than minShutter * 0.5
        if measuredShutter < minShutter * 0.5 && measuredISO <= maxISO * 0.3 {
            let relaxedShutter = min(minShutter, measuredShutter * 1.5)
            return (CMTime(seconds: relaxedShutter, preferredTimescale: 1_000_000), measuredISO)
        }

        return nil
    }
}
