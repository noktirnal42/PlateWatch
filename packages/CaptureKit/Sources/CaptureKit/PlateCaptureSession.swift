import AVFoundation
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
    private var adaptiveExposureController: AdaptiveExposureController?
    private var lastExposureDuration: CMTime?
    private var lastISO: Float?

    public init(configuration: CaptureConfiguration = .handheld) {
        self.configuration = configuration
        let fps = 30.0
        let totalSeconds = configuration.eventClipPreRollSeconds + configuration.eventClipPostRollSeconds
        let maxFrames = Int(totalSeconds * fps * 1.5) // 1.5x headroom
        self.rollingBuffer = FrameRollingBuffer(maxFrames: maxFrames)
        if configuration.enableAdaptiveExposure {
            self.adaptiveExposureController = AdaptiveExposureController(
                minShutter: configuration.minimumShutterSeconds,
                maxISO: configuration.maximumISO)
        }
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
                               minShutter: configuration.minimumShutterSeconds,
                               maxISO: configuration.maximumISO)
    }

    public func onFrame(_ consumer: @escaping @Sendable (FramePacket) -> Void) {
        self.consumer = consumer
    }

    /// Called when a fleet-classified event is detected to extract the event clip.
    public func onFleetEvent(_ consumer: @escaping @Sendable (EventClip) -> Void) {
        self.eventClipConsumer = consumer
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
    static func tuneForPlates(device: AVCaptureDevice, minShutter: Double, maxISO: Float) throws {
        #if !os(macOS) // Manual exposure APIs are iOS-only on capture devices.
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }

            if device.isExposureModeSupported(.custom) {
                let requested = CMTime(seconds: minShutter, preferredTimescale: 1_000_000)
                let minD = device.activeFormat.minExposureDuration
                let maxD = device.activeFormat.maxExposureDuration
                let shutter: CMTime
                if CMTimeCompare(requested, minD) < 0 { shutter = minD }
                else if CMTimeCompare(requested, maxD) > 0 { shutter = maxD }
                else { shutter = requested }
                let iso = min(maxISO, device.activeFormat.maxISO)
                device.setExposureModeCustom(duration: shutter, iso: iso) { _ in }
            }
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            device.automaticallyAdjustsVideoHDREnabled = false // HDR smears plates
        }
        #else
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            // macOS: just configure focus/HDR
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
        }
        #endif
    }

    /// Extracts an event clip around the current frame index.
    public func extractEventClip(triggerFrameIndex: Int) -> EventClip? {
        let preFrames = Int(configuration.eventClipPreRollSeconds * 30.0)
        let postFrames = Int(configuration.eventClipPostRollSeconds * 30.0)
        let start = max(0, triggerFrameIndex - preFrames)
        let end = min(Int(frameCounter) - 1, triggerFrameIndex + postFrames)
        let frames = rollingBuffer.extractClip(from: start, to: end)
        guard !frames.isEmpty else { return nil }
        return EventClip(
            frames: frames,
            triggerFrameIndex: triggerFrameIndex - start,
            triggerTimestamp: frames[triggerFrameIndex - start].timestamp
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

        // Extract exposure metadata for adaptive tuning
        let (exposureDuration, iso) = extractExposureMetadata(from: sampleBuffer)

        let packet = FramePacket(
            pixelBuffer: pixelBuffer,
            timestamp: Date(),
            sequenceNumber: frameCounter,
            exposureDuration: exposureDuration,
            iso: iso
        )

        rollingBuffer.append(packet)
        consumer?(packet)

        // Update adaptive exposure controller with actual exposure
        if let exp = exposureDuration, let isoVal = iso,
           let controller = adaptiveExposureController {
            let suggested = controller.update(measuredShutter: exp.seconds, measuredISO: isoVal)
            if let (shutter, newISO) = suggested {
                applyExposureAdjustment(shutter: shutter, iso: newISO)
            }
        }
    }

    private func applyExposureAdjustment(shutter: CMTime, iso: Float) {
        #if !os(macOS)
        guard let device = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first?.device else { return }
        do {
            try device.lockForConfiguration()
            defer { device.unlockForConfiguration() }
            if device.isExposureModeSupported(.custom) {
                device.setExposureModeCustom(duration: shutter, iso: iso) { _ in }
            }
        } catch {
            // Ignore transient lock failures
        }
        #endif
    }

    /// Extracts exposure metadata from sample buffer attachments.
    private func extractExposureMetadata(from sampleBuffer: CMSampleBuffer) -> (CMTime?, Float?) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[CFString: Any]],
              let dict = attachments.first else { return (nil, nil) }

        // Use string-based keys since the CFString constants aren't exposed in Swift
        let exposureDuration = dict["ExposureDuration" as CFString] as? CMTime
        let iso = dict["ExposureISO" as CFString] as? Float
        return (exposureDuration, iso)
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
