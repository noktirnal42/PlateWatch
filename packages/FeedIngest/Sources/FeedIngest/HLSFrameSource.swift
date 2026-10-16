import AVFoundation
import CoreVideo
import Foundation
import PlateKit

public protocol LiveFrameSink: Sendable {
    func accept(_ pixelBuffer: CVPixelBuffer, from source: PublicFeedSource) async
}

/// A serial, bounded HLS decoder. Terms are checked before an AVPlayerItem is created.
/// A private loopback relay checks every declared playlist, segment, key and redirect before fetching.
@MainActor
public final class HLSFrameSource {
    public enum State: Sendable, Equatable {
        case connecting, streaming, retrying(String), stopped
    }
    public let source: PublicFeedSource
    public let enforceTerms: Bool
    public var isPermitted: Bool { !enforceTerms || source.mayBeAnalysed }
    public private(set) var isRunning = false
    public private(set) var state: State = .stopped
    /// Called on the main actor when transport state changes, never once per frame.
    public var onStateChange: (@MainActor @Sendable (State) -> Void)?
    public var tapInterval: TimeInterval = 1.0 / 15.0
    private let stallTimeout: TimeInterval
    private let retryDelay: TimeInterval
    private let requestPolicy: HLSPolicyRelay.Policy?
    private var relay: HLSPolicyRelay?
    private let player = AVPlayer()
    private var output: AVPlayerItemVideoOutput?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    public init(source: PublicFeedSource, enforceTerms: Bool = true,
                stallTimeout: TimeInterval = 30, retryDelay: TimeInterval = 5,
                requestPolicy: HLSPolicyRelay.Policy? = nil) {
        precondition(source.kind == .hls, "HLSFrameSource is for .hls feeds")
        self.requestPolicy = requestPolicy
        self.source = source
        self.enforceTerms = enforceTerms
        self.stallTimeout = max(1, stallTimeout)
        self.retryDelay = max(0.1, retryDelay)
        player.isMuted = true
        player.automaticallyWaitsToMinimizeStalling = true
    }

    public func start(sink: any LiveFrameSink) {
        guard isPermitted, !isRunning else { return }
        isRunning = true
        let run = UUID()
        generation = run
        let policy: HLSPolicyRelay.Policy
        if let requestPolicy { policy = requestPolicy }
        else {
            let config = URLSessionConfiguration.ephemeral
            let robots = RobotsCache(session: URLSession(configuration: config),
                userAgent: "PlateWatchHub/0.1 (+https://github.com/noktirnal42/PlateWatch)",
                publicAPIPermissions: PublicAPIPermission.nevada511Video)
            let root = source.url
            policy = { url in
                guard url.scheme == root.scheme, url.host == root.host, (url.port ?? (url.scheme == "https" ? 443 : 80)) == (root.port ?? (root.scheme == "https" ? 443 : 80)) else { return false }
                return await robots.isAllowed(url)
            }
        }
        let relay = HLSPolicyRelay(url: source.url, policy: policy)
        self.relay = relay
        task = Task { @MainActor [weak self] in
            let playbackURL: URL
            do { playbackURL = try await relay.start() }
            catch {
                guard let self, self.isRunning, self.generation == run else { return }
                self.isRunning = false
                self.setState(.retrying("The local stream policy relay could not start."))
                relay.stop()
                return
            }
            // Only one sink delivery can be in flight. Awaiting it provides backpressure.
            // Reacquire self each iteration so an idle decoder is not retained by its own task.
            while !Task.isCancelled {
                guard let self, self.isRunning, self.generation == run else { return }
                self.openItem(url: playbackURL)
                var lastFrame = ContinuousClock.now
                while !Task.isCancelled, self.isRunning, self.generation == run {
                    if self.player.currentItem?.status == .failed { break }
                    if let output = self.output {
                        let itemTime = output.itemTime(forHostTime: CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock())))
                        if itemTime.isValid, output.hasNewPixelBuffer(forItemTime: itemTime),
                           let buffer = output.copyPixelBuffer(forItemTime: itemTime, itemTimeForDisplay: nil) {
                            lastFrame = .now
                            self.setState(.streaming)
                            await Self.deliver(Frame(buffer: buffer), source: self.source, sink: sink)
                            guard !Task.isCancelled, self.generation == run else { return }
                            // Sink latency is not a transport stall.
                            lastFrame = .now
                        }
                    }
                    if lastFrame.duration(to: .now) >= .seconds(self.stallTimeout) { break }
                    do { try await Task.sleep(for: .seconds(max(0.02, self.tapInterval.isFinite ? self.tapInterval : 1.0 / 15.0))) }
                    catch { return }
                }
                guard !Task.isCancelled, self.isRunning, self.generation == run else { return }
                let reason = relay.lastFailure ?? self.player.currentItem?.error?.localizedDescription ?? "No decoded frames; reconnecting"
                self.player.pause()
                self.player.replaceCurrentItem(with: nil)
                self.output = nil
                self.setState(.retrying(reason))
                do { try await Task.sleep(for: .seconds(self.retryDelay)) } catch { return }
            }
        }
    }

    public func stop() {
        generation = UUID()
        isRunning = false
        task?.cancel()
        task = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
        output = nil
        relay?.stop(); relay = nil
        setState(.stopped)
    }

    private func openItem(url: URL) {
        let item = AVPlayerItem(url: url)
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
        item.add(output)
        self.output = output
        player.replaceCurrentItem(with: item)
        setState(.connecting)
        player.play()
    }

    private func setState(_ value: State) {
        guard state != value else { return }
        state = value
        onStateChange?(value)
    }

    /// The buffer is immutable during delivery and owned by this one task.
    private struct Frame: @unchecked Sendable { let buffer: CVPixelBuffer }
    nonisolated private static func deliver(_ frame: Frame, source: PublicFeedSource, sink: any LiveFrameSink) async {
        await sink.accept(frame.buffer, from: source)
    }
}
