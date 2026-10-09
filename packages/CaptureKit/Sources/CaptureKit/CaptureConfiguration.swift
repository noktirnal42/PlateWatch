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

    public static let handheld = CaptureConfiguration(
        analyzeEveryNthFrame: 3, preset: .hd1920x1080, preferTelephoto: true,
        minimumShutterSeconds: 1.0 / 500.0)
    /// Dashcam: faster shutter, same sampling.
    public static let dashcam = CaptureConfiguration(
        analyzeEveryNthFrame: 2, preset: .hd1920x1080, preferTelephoto: true,
        minimumShutterSeconds: 1.0 / 1000.0)

    public init(analyzeEveryNthFrame: Int, preset: AVCaptureSession.Preset,
                preferTelephoto: Bool, minimumShutterSeconds: Double) {
        self.analyzeEveryNthFrame = analyzeEveryNthFrame
        self.preset = preset
        self.preferTelephoto = preferTelephoto
        self.minimumShutterSeconds = minimumShutterSeconds
    }
}

/// One camera frame handed to the analysis pipeline. The pixel buffer is
/// retained by the pipeline for the duration of analysis only.
public struct FramePacket: @unchecked Sendable {  // pixel buffers are reference-counted; analysis stages never retain them
    public let pixelBuffer: CVPixelBuffer
    public let timestamp: Date
    public let sequenceNumber: UInt64

    public init(pixelBuffer: CVPixelBuffer, timestamp: Date, sequenceNumber: UInt64) {
        self.pixelBuffer = pixelBuffer
        self.timestamp = timestamp
        self.sequenceNumber = sequenceNumber
    }
}
