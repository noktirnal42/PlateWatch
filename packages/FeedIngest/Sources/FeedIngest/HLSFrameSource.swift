import AVFoundation
import CoreVideo
import Foundation
import PlateKit

/// Sink for decoded live-video frames (HLS). Snapshot feeds use
/// `FeedFrameSink` (bytes); continuous feeds deliver pixel buffers.
public protocol LiveFrameSink: Sendable {
    func accept(_ pixelBuffer: CVPixelBuffer, from source: PublicFeedSource) async
}

/// Decodes a public HLS (.m3u8) camera feed and taps decoded video frames —
/// the display path that pure AVFoundation supports for live streams
/// (RTSP needs the VLCKit fallback, see docs/CAMERA-SOURCES.md).
///
/// **Status: implemented, not yet verified against a live feed.** CI has no
/// network/no camera; verify with a real 511 HLS URL before marking the M6
/// roadmap box. Nothing here touches persistence — frames go to a
/// `LiveFrameSink`, and the receiving pipeline still runs the RedactionGate.
public final class HLSFrameSource: @unchecked Sendable {
    public let source: PublicFeedSource
    private let player: AVPlayer
    private let output: AVPlayerItemVideoOutput
    private let queue = DispatchQueue(label: "org.platewatch.feedingest.hls", qos: .utility)
    private var running = false
    /// Decoded-frame tap rate. Analysis cadence (analyze-every-Nth) is the
    /// pipeline's job; this just avoids copying every decoder frame.
    public var tapInterval: TimeInterval = 1.0 / 15.0

    public init(source: PublicFeedSource) {
        precondition(source.kind == .hls, "HLSFrameSource is for .hls feeds")
        self.source = source
        let item = AVPlayerItem(url: source.url)
        self.output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ])
        item.add(output)
        self.player = AVPlayer(playerItem: item)
        player.isMuted = true
        player.actionAtItemEnd = .none
        // Live streams: keep the item playing at the live edge.
        player.automaticallyWaitsToMinimizeStalling = false
    }

    public var isRunning: Bool { running }

    /// Begin decoding and delivering frames until `stop()`.
    public func start(sink: any LiveFrameSink) {
        guard !running else { return }
        running = true
        player.play()
        tapLoop(sink: sink)
    }

    public func stop() {
        running = false
        player.pause()
    }

    private func tapLoop(sink: any LiveFrameSink) {
        queue.async { [weak self] in
            guard let self, self.running else { return }
            let hostTime = CMClockGetTime(CMClockGetHostTimeClock())
            let itemTime = self.output.itemTime(forHostTime: CMTimeGetSeconds(hostTime))
            // copyPixelBuffer returns nil when no new frame is available at
            // this item time; guard against re-delivering the same frame.
            if itemTime.isValid, itemTime.seconds > self.lastTappedTime,
               let pixelBuffer = self.output.copyPixelBuffer(forItemTime: itemTime,
                                                             itemTimeForDisplay: nil) {
                self.lastTappedTime = itemTime.seconds
                Task { await sink.accept(pixelBuffer, from: self.source) }
            }
            self.queue.asyncAfter(deadline: .now() + self.tapInterval) { [weak self] in
                self?.tapLoop(sink: sink)
            }
        }
    }

    private var lastTappedTime: Double = -.infinity
}
