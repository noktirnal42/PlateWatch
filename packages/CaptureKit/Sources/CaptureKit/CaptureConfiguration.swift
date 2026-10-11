import AVFoundation
import CoreMedia
import Foundation

/// Configuration tuned for plate-reading physics: resolution and shutter
/// discipline matter more than frame rate.
public struct CaptureConfiguration: Sendable {
    /// Analysis sample rate. Full-rate inference on every frame is a
    /// thermal trap; every 3rd frame at 30 fps is a good default.
    public var analyzeEveryNthFrame: Int
    public var preset: AVCaptureSession.Preset
    /// Prefer the telephoto camera when present (plate reach ~2× wide).
    public var preferTelephoto: Bool
    /// Target minimum shutter for moving traffic. Enforced when the device
    /// allows manual exposure; otherwise we bias ISO down via exposure target.
    public var minimumShutterSeconds: Double
    /// Maximum ISO before we accept a slower shutter (iOS only).
    public var maximumISO: Float
    /// Enable adaptive exposure tuning that reacts to scene brightness.
    public var enableAdaptiveExposure: Bool
    /// Seconds of pre-event frames to retain for event clips.
    public var eventClipPreRollSeconds: Double
    /// Seconds of post-event frames to retain for event clips.
    public var eventClipPostRollSeconds: Double

    public static let handheld = CaptureConfiguration(
        analyzeEveryNthFrame: 3, preset: .hd1920x1080, preferTelephoto: true,
        minimumShutterSeconds: 1.0 / 500.0, maximumISO: 800,
        enableAdaptiveExposure: true, eventClipPreRollSeconds: 2.0, eventClipPostRollSeconds: 1.0)
    /// Dashcam: faster shutter, same sampling.
    public static let dashcam = CaptureConfiguration(
        analyzeEveryNthFrame: 2, preset: .hd1920x1080, preferTelephoto: true,
        minimumShutterSeconds: 1.0 / 1000.0, maximumISO: 1600,
        enableAdaptiveExposure: true, eventClipPreRollSeconds: 3.0, eventClipPostRollSeconds: 2.0)

    public init(analyzeEveryNthFrame: Int, preset: AVCaptureSession.Preset,
                preferTelephoto: Bool, minimumShutterSeconds: Double,
                maximumISO: Float = 800, enableAdaptiveExposure: Bool = true,
                eventClipPreRollSeconds: Double = 2.0, eventClipPostRollSeconds: Double = 1.0) {
        self.analyzeEveryNthFrame = analyzeEveryNthFrame
        self.preset = preset
        self.preferTelephoto = preferTelephoto
        self.minimumShutterSeconds = minimumShutterSeconds
        self.maximumISO = maximumISO
        self.enableAdaptiveExposure = enableAdaptiveExposure
        self.eventClipPreRollSeconds = eventClipPreRollSeconds
        self.eventClipPostRollSeconds = eventClipPostRollSeconds
    }
}

/// One camera frame handed to the analysis pipeline. The pixel buffer is
/// retained by the pipeline for the duration of analysis only.
public struct FramePacket: @unchecked Sendable {  // pixel buffers are reference-counted; analysis stages never retain them
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: Date
    public let sequenceNumber: UInt64
    /// Exposure metadata for adaptive tuning feedback.
    public let exposureDuration: CMTime?
    public let iso: Float?

    public init(pixelBuffer: CVPixelBuffer, timestamp: Date, sequenceNumber: UInt64,
                exposureDuration: CMTime? = nil, iso: Float? = nil) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
        self.exposureDuration = exposureDuration
        self.iso = iso
    }
}

/// A rolling buffer of recent frames for event clip extraction.
public final class FrameRollingBuffer: @unchecked Sendable {
    private let maxFrames: Int
    private var frames: [FramePacket] = []
    private let lock = NSLock()

    public init(maxFrames: Int) {
        self.maxFrames = maxFrames
    }

    public func append(_ frame: FramePacket) {
        lock.lock()
        defer { lock.unlock() }
        frames.append(frame)
        if frames.count > maxFrames { frames.removeFirst(frames.count - maxFrames) }
    }

    /// Extracts the frames whose sequence numbers fall in
    /// [startIndex, endIndex] inclusive. Indices are ABSOLUTE frame numbers
    /// (the `FramePacket.sequenceNumber` space), not buffer positions:
    /// frames already evicted by the rolling window are simply absent, and
    /// an empty or inverted range returns [] rather than crashing. This is
    /// what `PlateCaptureSession.extractEventClip` assumes when it passes
    /// raw frame-counter indices.
    public func extractClip(from startIndex: Int, to endIndex: Int) -> [FramePacket] {
        lock.lock()
        defer { lock.unlock() }
        let start = max(0, startIndex)
        let end = max(0, endIndex)
        return frames.filter { $0.sequenceNumber >= start && $0.sequenceNumber <= end }
    }

    /// Returns frames within a time window ending at the most recent frame.
    public func framesInLast(_ seconds: Double) -> [FramePacket] {
        lock.lock()
        defer { lock.unlock() }
        let cutoff = Date().addingTimeInterval(-seconds)
        return frames.filter { $0.timestamp >= cutoff }
    }

    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }
}

/// Result of an event clip extraction.
public struct EventClip: Sendable {
    public let frames: [FramePacket]
    public let triggerFrameIndex: Int
    public let triggerTimestamp: Date

    public init(frames: [FramePacket], triggerFrameIndex: Int, triggerTimestamp: Date) {
        self.frames = frames
        self.triggerFrameIndex = triggerFrameIndex
        self.triggerTimestamp = triggerTimestamp
    }
}
