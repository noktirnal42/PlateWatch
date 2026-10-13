import AVFoundation
import CoreMedia
import Foundation

/// RTSP/HLS frame source for IP camera streams.
/// Uses AVAssetReader for HLS/m3u8 streams (common camera output).
/// For raw RTSP, integrate VLCKit via `RTSPFrameSourceVLC` (separate target).
/// All sources normalize to `FramePacket` so the pipeline never knows the difference.
public final class RTSPFrameSource: @unchecked Sendable {

    public enum SourceError: Error {
        case invalidURL
        case assetLoadFailed(Error)
        case readerSetupFailed(Error)
        case noVideoTrack
        case readFailed(Error)
        case cancelled
    }

    public struct Configuration: Sendable {
        /// Target analysis frame rate (frames per second to emit).
        /// Source video may be higher; we sample down.
        public var targetFPS: Double
        /// Maximum time to wait for initial segment load.
        public var initialLoadTimeout: TimeInterval
        /// Buffer duration to maintain ahead of playback (seconds).
        public var bufferDuration: TimeInterval

        public static let `default` = Configuration(
            targetFPS: 5.0,           // 5 fps analysis is plenty for ALPR
            initialLoadTimeout: 10.0,
            bufferDuration: 2.0)

        public init(targetFPS: Double = 5.0, initialLoadTimeout: TimeInterval = 10.0, bufferDuration: TimeInterval = 2.0) {
            self.targetFPS = targetFPS
            self.initialLoadTimeout = initialLoadTimeout
            self.bufferDuration = bufferDuration
        }
    }

    private let streamURL: URL
    private let configuration: Configuration
    private var asset: AVAsset?
    private var reader: AVAssetReader?
    private var videoTrack: AVAssetTrack?
    private var readerOutput: AVAssetReaderTrackOutput?
    private var frameCounter: UInt64 = 0
    private var isRunning = false
    private var consumer: (@Sendable (FramePacket) -> Void)?
    private let processingQueue = DispatchQueue(label: "org.platewatch.rtsp.frames", qos: .userInitiated)
    private var lastEmittedTimestamp: CMTime = .zero
    private let frameInterval: CMTime

    public init(streamURL: URL, configuration: Configuration = .default) {
        self.streamURL = streamURL
        self.configuration = configuration
        self.frameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.targetFPS))
    }

    /// Called for each decoded frame.
    public func onFrame(_ consumer: @escaping @Sendable (FramePacket) -> Void) {
        self.consumer = consumer
    }

    /// Start ingesting the stream. Loads asset, prepares reader, begins pumping frames.
    public func start() async throws {
        guard !isRunning else { return }
        isRunning = true

        // Load asset asynchronously
        let asset = AVAsset(url: streamURL)
        self.asset = asset

        do {
            // Load tracks (waits for m3u8 manifest + first segment)
            _ = try await asset.load(.tracks, .duration)
        } catch {
            isRunning = false
            throw SourceError.assetLoadFailed(error)
        }

        // Use modern API for loading video tracks
        let videoTracks = try await asset.loadTracks(withMediaType: .video)
        guard let videoTrack = videoTracks.first else {
            isRunning = false
            throw SourceError.noVideoTrack
        }
        self.videoTrack = videoTrack

        // Configure reader output for BGRA pixel buffers
        let outputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 1920,
            kCVPixelBufferHeightKey as String: 1080,
        ]
        let readerOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: outputSettings)
        readerOutput.alwaysCopiesSampleData = false // zero-copy where possible
        self.readerOutput = readerOutput

        do {
            let reader = try AVAssetReader(asset: asset)
            if reader.canAdd(readerOutput) {
                reader.add(readerOutput)
            } else {
                throw SourceError.readerSetupFailed(NSError(domain: "RTSPFrameSource", code: -1,
                    userInfo: [NSLocalizedDescriptionKey: "Cannot add reader output"]))
            }
            self.reader = reader
        } catch {
            isRunning = false
            throw SourceError.readerSetupFailed(error)
        }

        self.reader?.startReading()
        processingQueue.async { [weak self] in
            self?.pumpFrames()
        }
    }

    /// Stop ingesting and release resources.
    public func stop() {
        isRunning = false
        reader?.cancelReading()
        reader = nil
        readerOutput = nil
        videoTrack = nil
        asset = nil
    }

    private func pumpFrames() {
        guard let reader, let readerOutput, isRunning else { return }

        while isRunning, let sampleBuffer = readerOutput.copyNextSampleBuffer() {
            // Rate-limit to targetFPS
            let presentationTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if lastEmittedTimestamp != .zero {
                let elapsed = CMTimeSubtract(presentationTime, lastEmittedTimestamp)
                if CMTimeCompare(elapsed, frameInterval) < 0 {
                    continue // skip frame to maintain target FPS
                }
            }
            lastEmittedTimestamp = presentationTime

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { continue }

            frameCounter &+= 1
            let packet = FramePacket(
                pixelBuffer: pixelBuffer,
                timestamp: Date(), // approximate; could use presentationTime
                sequenceNumber: frameCounter
            )
            consumer?(packet)
        }

        // Stream error or clean end: stop emitting. Never synthesize a
        // frame here — a black dummy buffer would enter the analysis
        // pipeline (and the rolling event clip) as if it were a real
        // observation, and CVPixelBufferCreate can fail.
        isRunning = false
    }
}

/// Convenience factory for common camera stream patterns.
public extension RTSPFrameSource {
    /// Create from an HLS/m3u8 URL (most IP cameras expose this alongside RTSP).
    static func hls(_ url: URL, configuration: Configuration = .default) -> RTSPFrameSource {
        RTSPFrameSource(streamURL: url, configuration: configuration)
    }

    /// Create from an RTSP URL (requires transcoding to HLS or VLCKit).
    /// For now, treats as HLS; VLCKit integration would override this.
    static func rtsp(_ url: URL, configuration: Configuration = .default) -> RTSPFrameSource {
        RTSPFrameSource(streamURL: url, configuration: configuration)
    }
}

/// Protocol for pluggable RTSP backends (AVFoundation, VLCKit, GStreamer, etc.)
public protocol RTSPBackend: Sendable {
    func start() async throws
    func stop()
    func onFrame(_ consumer: @escaping @Sendable (FramePacket) -> Void)
}

/// VLCKit backend stub — implement in a separate target that links VLCKit.
/// This keeps the main CaptureKit dependency-free.
public final class RTSPFrameSourceVLC: @unchecked Sendable, RTSPBackend {
    private let streamURL: URL
    private var isRunning = false
    private let lock = NSLock()

    public init(streamURL: URL) {
        self.streamURL = streamURL
    }

    public func start() async throws {
        // TODO: Link VLCKit and implement libvlc media player with video callbacks
        // that convert vlc picture_t -> CVPixelBuffer -> FramePacket.
        throw NSError(domain: "RTSPFrameSourceVLC", code: -1,
            userInfo: [NSLocalizedDescriptionKey: "VLCKit backend not linked. Add VLCKit dependency and implement."])
    }

    public func stop() {
        lock.lock()
        isRunning = false
        lock.unlock()
    }

    public func onFrame(_ consumer: @escaping @Sendable (FramePacket) -> Void) {
        // Store consumer for VLC video callback
    }
}