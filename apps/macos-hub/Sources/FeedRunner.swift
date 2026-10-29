import CryptoKit
import AVFoundation
import CoreVideo
import CoreImage
import FeedIngest
import Foundation
import SwiftUI

/// One shared request budget per host. Preview requests can pass queued background polls;
/// cancellation removes a waiter instead of reserving thousands of future time slots.
actor HostThrottle {
    private struct Waiter { let id: UUID; let continuation: CheckedContinuation<Bool, Never> }
    private let interval: Duration
    private var queues: [String: [Waiter]] = [:]
    private var workers: [String: Task<Void, Never>] = [:]
    private var nextAllowed: [String: ContinuousClock.Instant] = [:]

    init(interval: TimeInterval = 1) { self.interval = .seconds(max(0, interval)) }

    func acquire(host: String, interactive: Bool = false) async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                let waiter = Waiter(id: id, continuation: continuation)
                if interactive { queues[host, default: []].insert(waiter, at: 0) }
                else { queues[host, default: []].append(waiter) }
                if workers[host] == nil { workers[host] = Task { await self.drain(host) } }
            }
        } onCancel: {
            Task { await self.cancel(id, host: host) }
        }
    }

    private func cancel(_ id: UUID, host: String) {
        guard let index = queues[host]?.firstIndex(where: { $0.id == id }),
              let waiter = queues[host]?.remove(at: index) else { return }
        waiter.continuation.resume(returning: false)
    }

    private func drain(_ host: String) async {
        while queues[host]?.isEmpty == false {
            if let deadline = nextAllowed[host] { try? await ContinuousClock().sleep(until: deadline) }
            guard queues[host]?.isEmpty == false, let waiter = queues[host]?.removeFirst() else { break }
            nextAllowed[host] = ContinuousClock.now.advanced(by: interval)
            waiter.continuation.resume(returning: true)
        }
        queues[host] = nil
        workers[host] = nil
    }
}

@MainActor
final class FeedRunner: ObservableObject {
    @Published private(set) var status = "No feeds configured"
    @Published private(set) var runningCount = 0
    @Published private(set) var awaitingTermsCount = 0
    static let userAgent = "PlateWatchHub/0.1 (+https://github.com/noktirnal42/PlateWatch)"

    enum SourceState: Equatable {
        case checking, polling, blockedByRobots, blockedByUser, suspended, videoIdle, videoConnecting
        case policyUnavailable(String)
        case videoUnavailable(String), imageUnavailable(String)
    }
    /// Per-camera status. Deliberately **not** `@Published`: thousands of cameras change state in bursts (start-up, a host's
    /// robots.txt answering), and a publish per camera re-rendered the whole table thousands of times and froze the UI.
    /// Changes are coalesced into at most one refresh per half second instead.
    private(set) var sourceStates: [UUID: SourceState] = [:] { didSet { scheduleStateRefresh() } }
    @Published private(set) var stateRevision = 0
    private static let previewBudget = HLSPreviewBudget()
    private var snapshotDigests: [UUID: SHA256.Digest] = [:]
    private(set) var contentChangedAt: [UUID: Date] = [:]
    private(set) var lastReceivedAt: [UUID: Date] = [:]
    private var stateRefreshPending = false
    private func scheduleStateRefresh() {
        guard !stateRefreshPending else { return }
        stateRefreshPending = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            self?.stateRefreshPending = false
            self?.stateRevision &+= 1
        }
    }
    enum StatusKind: String, CaseIterable, Identifiable {
        case checking = "Checking robots.txt", polling = "Polling", confirmed = "Confirmed (idle)"
        case frameUnavailable = "Camera image unavailable"
        case unavailable = "Policy temporarily unavailable"
        case awaiting = "Awaiting terms", blocked = "Blocked / refused", userBlocked = "Blocked by you", suspended = "Suspended"
        var id: String { rawValue }
    }
    struct Display { let text: String; let icon: String; let color: Color; let kind: StatusKind }
    func state(of source: PublicFeedSource) -> Display {
        if blockedIDs.contains(source.id) { return .init(text: "Blocked on this Mac", icon: "nosign", color: .secondary, kind: .userBlocked) }
        guard source.mayBeAnalysed else { return .init(text: "Awaiting terms", icon: "hourglass", color: .orange, kind: .awaiting) }
        switch sourceStates[source.id] {
        case .checking: return .init(text: source.kind == .hls && hlsSources[source.id] != nil ? "Connecting video…" : "Checking robots.txt…", icon: "clock", color: .secondary, kind: .checking)
        case .polling: return .init(text: "Polling", icon: "checkmark.circle.fill", color: .green, kind: .polling)
        case .videoUnavailable: return .init(text: "Video unavailable; reconnecting", icon: "video.badge.ellipsis", color: .orange, kind: .unavailable)
        case .policyUnavailable: return .init(text: "Policy temporarily unavailable", icon: "arrow.clockwise", color: .orange, kind: .unavailable)
        case .blockedByRobots: return .init(text: "Host policy refused", icon: "hand.raised.fill", color: .red, kind: .blocked)
        case .blockedByUser: return .init(text: "Blocked on this Mac", icon: "nosign", color: .secondary, kind: .userBlocked)
        case .imageUnavailable(let reason): return .init(text: reason, icon: "photo.badge.exclamationmark", color: .orange, kind: .frameUnavailable)
        case .videoConnecting: return .init(text: "Connecting HLS (NV511 can take 30–60 s)…", icon: "video", color: .secondary, kind: .checking)
        case .videoIdle: return .init(text: watchedIDs.contains(source.id) && explicitWatchSelection ? "HLS queued · rotating" : "HLS ready · watch or open in Live", icon: "play.circle", color: .secondary, kind: .confirmed)
        case .suspended: return source.kind == .rtsp
            ? .init(text: "RTSP needs the VLCKit fallback (not bundled)", icon: "video.slash", color: .secondary, kind: .suspended)
            : .init(text: "Suspended after repeated failures", icon: "exclamationmark.triangle.fill", color: .orange, kind: .suspended)
        case nil: return .init(text: "Confirmed (idle)", icon: "checkmark.circle", color: .secondary, kind: .confirmed)
        }
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var hostTasks: [String: Task<Void, Never>] = [:]
    private var previewTasks: [UUID: [UUID: Task<Data, Error>]] = [:]
    private var generation = UUID()
    private var catalogue: FeedCatalogue?
    private var sink: ClosureSink?
    private var videoSink: ClosureVideoSink?
    /// Live decoders for `.hls` sources, keyed by source id (stopped in `stop()`/on block).
    var activeVideoCount: Int { hlsSources.count }
    /// The player of a running HLS decoder (the Live-pinned one), for on-screen playback. Nil until the decoder exists.
    func livePlayer(for id: UUID) -> AVPlayer? { hlsSources[id]?.player }
    /// True once the decoder reports frames flowing (the Live pane then shows moving video instead of sampled stills).
    func isStreaming(_ id: UUID) -> Bool { hlsSources[id] != nil && sourceStates[id] == .polling }
    /// Number of watched HLS sources waiting for their turn in the bounded
    /// rotation. Keeping this separate from `activeVideoCount` makes the
    /// status row explain why a catalogue can be healthy while most HLS rows
    /// say "queued".
    var queuedVideoCount: Int { max(0, eligibleHLSIDs.count - activeVideoCount) }
    private var requestedHLSID: UUID?
    private var hlsRotation: Task<Void, Never>?
    private var hlsRotationOffset = 0
    private var hlsSources: [UUID: HLSFrameSource] = [:]
    private var watchedIDs: Set<UUID> = []
    private var explicitWatchSelection = false
    static let maxConcurrentHLS = 4
    private var eligibleHLSIDs: [UUID] {
        (catalogue?.runnable ?? []).filter { source in
            source.kind == .hls && !blockedIDs.contains(source.id) && watchedIDs.contains(source.id)
                && (explicitWatchSelection || source.id == requestedHLSID)
        }.map(\.id).sorted { $0.uuidString < $1.uuidString }
    }
    var scheduledVideoIDs: Set<UUID> {
        let eligible = eligibleHLSIDs
        let pinned = requestedHLSID.flatMap { eligible.contains($0) ? $0 : nil }
        let background = eligible.filter { $0 != pinned }
        var selected = Set(pinned.map { [$0] } ?? [])
        // While the camera on screen is still connecting, background watches wait: they hit the same slow NV511 hosts from the
        // same address and measurably starve the stream the operator is looking at (2026-10-22). They resume once it streams.
        let pinnedConnecting = pinned.map { sourceStates[$0] == .videoConnecting } ?? false
        let slots = !pinnedConnecting ? min(Self.maxConcurrentHLS - selected.count, background.count) : 0
        for index in 0..<slots { selected.insert(background[(hlsRotationOffset + index) % background.count]) }
        return selected
    }
    private var selectedHLSIDs: Set<UUID> { scheduledVideoIDs }

    /// All explicitly watched HLS feeds get a turn; Live stays pinned.
    func rotateVideoWatches() {
        let eligible = eligibleHLSIDs
        guard eligible.count > Self.maxConcurrentHLS else { return }
        let pinned = requestedHLSID.map { eligible.contains($0) } == true ? 1 : 0
        hlsRotationOffset = (hlsRotationOffset + Self.maxConcurrentHLS - pinned) % (eligible.count - pinned)
        setLiveVideoSource(requestedHLSID)
    }
    private var blockedIDs: Set<UUID> = []
    private let session: URLSession
    private let robots: RobotsCache
    private let throttle: HostThrottle
    private let retryInterval: Duration

    init(session: URLSession? = nil, throttleInterval: TimeInterval = 1, retryInterval: Duration = .seconds(60), publicAPIPermissions: [PublicAPIPermission] = [.caltransCCTV] + PublicAPIPermission.nevada511Video) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        let session = session ?? URLSession(configuration: config)
        self.session = session
        self.robots = RobotsCache(session: session, userAgent: Self.userAgent, publicAPIPermissions: publicAPIPermissions)
        self.throttle = HostThrottle(interval: throttleInterval)
        self.retryInterval = retryInterval
    }

    func start(catalogue: FeedCatalogue, blockedIDs: Set<UUID> = [], watchedIDs: Set<UUID>? = nil,
               analyse: @escaping @Sendable @MainActor (Data, PublicFeedSource) async -> Void,
               analyseVideoFrame: (@Sendable @MainActor (PixelBufferBox, PublicFeedSource) async -> Void)? = nil) {
        stop()
        self.catalogue = catalogue
        self.explicitWatchSelection = watchedIDs != nil
        self.watchedIDs = watchedIDs ?? Set(catalogue.runnable.map(\.id))
        let run = generation
        self.sink = ClosureSink { [weak self] data, source in
            guard let self, self.mayFetch(source.id, run: run), self.watchedIDs.contains(source.id), !Task.isCancelled else { return }
            self.noteSnapshot(data, id: source.id)
            await analyse(data, source)
        }
        self.videoSink = analyseVideoFrame.map { handler in
            ClosureVideoSink { [weak self] buffer, source in
                guard let self, self.mayFetch(source.id, run: run), self.watchedIDs.contains(source.id), !Task.isCancelled else { return }
                self.lastReceivedAt[source.id] = Date()
                await handler(buffer, source)
            }
        }
        self.blockedIDs = blockedIDs
        if videoSink != nil {
            hlsRotation = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(60)) } catch { return }
                    guard let self, self.generation == run else { return }
                    self.rotateVideoWatches()
                }
            }
        }
        awaitingTermsCount = catalogue.awaitingTerms.filter { !blockedIDs.contains($0.id) }.count
        sourceStates = Dictionary(uniqueKeysWithValues: catalogue.sources.compactMap { source in
            if blockedIDs.contains(source.id) { return (source.id, .blockedByUser) }
            guard self.watchedIDs.contains(source.id) else { return nil }
            return source.mayBeAnalysed ? (source.id, .checking) : nil
        })
        for sources in Dictionary(grouping: catalogue.runnable.filter { self.watchedIDs.contains($0.id) }, by: { Self.origin($0.url) }).values {
            checkPolicy(for: sources)
        }
        updateStatus()
    }

    /// Replace background selection without restarting unrelated cameras or previews.
    func setWatched(_ ids: Set<UUID>) {
        let old = watchedIDs
        guard old != ids else { return }
        watchedIDs = ids
        explicitWatchSelection = true
        for id in old.subtracting(ids) {
            tasks.removeValue(forKey: id)?.cancel()
            stopHLS(id)
            if !blockedIDs.contains(id) { sourceStates[id] = nil }
        }
        let addedIDs = ids.subtracting(old)
        let added = (catalogue?.runnable ?? []).filter { addedIDs.contains($0.id) && !blockedIDs.contains($0.id) }
        for source in added { sourceStates[source.id] = .checking }
        // Policy setup can span hundreds of hosts after a bulk watch action.
        // Yield between host groups so the main-actor UI remains responsive;
        // cancellation and generation checks still make stale groups harmless.
        let groups = Dictionary(grouping: added, by: { Self.origin($0.url) })
        Task { @MainActor [weak self] in
            for group in groups.values {
                guard let self, self.watchedIDs == ids else { return }
                guard let first = group.first else { continue }
                let origin = Self.origin(first.url)
                self.checkPolicy(for: self.catalogue?.runnable.filter { Self.origin($0.url) == origin } ?? group)
                await Task.yield()
            }
        }
        setLiveVideoSource(requestedHLSID)
        updateStatus()
    }

    /// Cancel just this camera, including in-flight previews. Unblock rechecks policy without restarting every other camera.
    func setBlocked(_ id: UUID, blocked: Bool) {
        if blocked {
            blockedIDs.insert(id)
            tasks.removeValue(forKey: id)?.cancel()
            previewTasks.removeValue(forKey: id)?.values.forEach { $0.cancel() }
            stopHLS(id)
            sourceStates[id] = .blockedByUser
        } else {
            blockedIDs.remove(id)
            sourceStates[id] = nil
            if let source = catalogue?.sources.first(where: { $0.id == id }), source.mayBeAnalysed, watchedIDs.contains(id) {
                sourceStates[id] = .checking
                checkPolicy(for: catalogue?.runnable.filter { Self.origin($0.url) == Self.origin(source.url) } ?? [])
            }
        }
        setLiveVideoSource(requestedHLSID)
        awaitingTermsCount = catalogue?.awaitingTerms.filter { !blockedIDs.contains($0.id) }.count ?? 0
        updateStatus()
    }

    /// Cache by origin, but evaluate each camera's path: one disallowed path must not block an allowed sibling.
    private func checkPolicy(for sources: [PublicFeedSource]) {
        guard let first = sources.first else { return }
        let origin = Self.origin(first.url), run = generation
        hostTasks[origin]?.cancel()
        hostTasks[origin] = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == run else { return }
                let pending = sources.filter { self.watchedIDs.contains($0.id) && !self.blockedIDs.contains($0.id) && self.tasks[$0.id] == nil && self.sourceStates[$0.id] != .suspended }
                var decisions: [UUID: RobotsDecision] = [:]
                let answers = await self.robots.decisions(for: pending.map(\.url))      // one hop for the whole host
                guard !Task.isCancelled, self.generation == run else { return }
                for (source, answer) in zip(pending, answers) { decisions[source.id] = answer }
                for source in pending where self.watchedIDs.contains(source.id) && !self.blockedIDs.contains(source.id) {
                    switch decisions[source.id] {
                    case .allowed: self.beginPolling(source, run: run)
                    case .unavailable(let reason): self.sourceStates[source.id] = .policyUnavailable(reason)
                    default: self.sourceStates[source.id] = .blockedByRobots
                    }
                }
                self.updateStatus()
                // Keep checking blocked paths; a transient lookup failure expires after one minute.
                do { try await Task.sleep(for: self.retryInterval) } catch { return }
            }
        }
    }

    private func beginPolling(_ source: PublicFeedSource, run: UUID) {
        guard tasks[source.id] == nil, !blockedIDs.contains(source.id), watchedIDs.contains(source.id) else { return }
        switch source.kind {
        case .snapshotJPEG:
            guard sink != nil else { return }
            beginSnapshotPolling(source, run: run)
        case .hls:
            beginHLSPolling(source, run: run)
        case .rtsp:
            // Raw RTSP needs an RTP/RTSP client (the VLCKit fallback path in
            // docs/CAMERA-SOURCES.md); none is bundled. State it, never pretend.
            sourceStates[source.id] = .suspended
        }
    }

    private func beginSnapshotPolling(_ source: PublicFeedSource, run: UUID) {
        guard let sink else { return }
        let id = source.id, robots = self.robots, throttle = self.throttle
        sourceStates[id] = .polling
        let poller = SnapshotPoller(source: source, sink: sink, session: session, onOutcome: { [weak self] outcome in
            await self?.recordSnapshotOutcome(outcome, sourceID: id, run: run)
        }, gate: { [weak self] url in
            guard !Task.isCancelled, await robots.isAllowed(url) else {
                await self?.markRobotsBlocked(id, run: run)
                return false
            }
            guard await throttle.acquire(host: url.host ?? ""), !Task.isCancelled else { return false }
            guard await self?.mayFetch(id, run: run) == true else { return false }
            let allowed = await robots.isAllowed(url)
            if !allowed { await self?.markRobotsBlocked(id, run: run) }
            return allowed && !Task.isCancelled
        })
        tasks[id] = Task { [weak self] in
            await poller.run(sink: sink)
            guard let self, !Task.isCancelled, self.generation == run else { return }
            self.tasks[id] = nil
            switch self.sourceStates[id] {
            case .polling, .imageUnavailable: self.sourceStates[id] = .suspended
            default: break
            }
            self.updateStatus()
        }
    }

    private func noteSnapshot(_ data: Data, id: UUID) {
        let date = Date(), digest = SHA256.hash(data: data)
        lastReceivedAt[id] = date
        if snapshotDigests[id] != digest {
            snapshotDigests[id] = digest
            contentChangedAt[id] = date
        }
        scheduleStateRefresh()
    }

    private func recordSnapshotOutcome(_ outcome: SnapshotPoller.Outcome, sourceID: UUID, run: UUID) {
        guard mayFetch(sourceID, run: run), watchedIDs.contains(sourceID) else { return }
        switch outcome {
        case .received(let date): lastReceivedAt[sourceID] = date; sourceStates[sourceID] = .polling
        case .httpFailure(let code): sourceStates[sourceID] = .imageUnavailable("Camera HTTP \(code) · retrying")
        case .unreadableImage: sourceStates[sourceID] = .imageUnavailable("Camera returned unreadable media · retrying")
        case .networkFailure(let code): sourceStates[sourceID] = .imageUnavailable("Camera connection failed (\(code)) · retrying")
        }
        updateStatus()
    }

    private func mayFetch(_ id: UUID, run: UUID) -> Bool { generation == run && !blockedIDs.contains(id) }

    /// Watched HLS cameras decode through the same reviewed-origin/robots
    /// policy relay as bounded previews. The relay mediates child resources and
    /// redirects; the decoder supplies sampled frames to the ordinary fleet gate.
    /// Explicit watches rotate through at most four streams, pinning Live.
    /// Catalogue approval alone never starts hundreds of AVPlayers.
    func setLiveVideoSource(_ id: UUID?) {
        requestedHLSID = id
        let selected = selectedHLSIDs
        for old in Array(hlsSources.keys) where !selected.contains(old) {
            stopHLS(old)
            if !blockedIDs.contains(old) { sourceStates[old] = watchedIDs.contains(old) ? .videoIdle : nil }
        }
        let videoOrigins = Set((catalogue?.runnable ?? []).filter { selected.contains($0.id) }.map { Self.origin($0.url) })
        for origin in videoOrigins {
            checkPolicy(for: catalogue?.runnable.filter { Self.origin($0.url) == origin } ?? [])
        }
        updateStatus()
    }

    /// Drop and recreate one selected HLS decoder without restarting all
    /// snapshot polling. This is used by the Live retry action after a
    /// provider has left a stale player connected.
    func retryLiveVideoSource(_ source: PublicFeedSource) {
        guard source.kind == .hls, source.id == requestedHLSID else { return }
        stopHLS(source.id)
        sourceStates[source.id] = .videoConnecting
        beginHLSPolling(source, run: generation)
        updateStatus()
    }

    /// A redirect or playlist reference may only use an origin whose media terms
    /// are already approved in this catalogue. The robots decision is per path.
    private func resourcePolicy(for source: PublicFeedSource) -> HLSPolicyRelay.Policy {
        let origins = Set((catalogue?.runnable ?? [source]).filter { !blockedIDs.contains($0.id) }.map { Self.origin($0.url) })
        let robots = self.robots
        return { url in
            guard origins.contains(Self.origin(url)) else { return false }
            return await robots.isAllowed(url)
        }
    }

    private func beginHLSPolling(_ source: PublicFeedSource, run: UUID) {
        guard let videoSink, !hlsSources.keys.contains(source.id) else {
            if videoSink == nil { sourceStates[source.id] = .suspended }
            return
        }
        guard selectedHLSIDs.contains(source.id) else { sourceStates[source.id] = .videoIdle; return }
        let id = source.id
        sourceStates[id] = .videoConnecting
        // Surface dead provider segments promptly. The Live pane has an
        // explicit retry action, so a short bounded attempt is preferable to
        // leaving a video tile in "Connecting" for half a minute.
        // The camera the operator is watching gets more patience: NV511 hosts often take 10–60 s to answer a playlist request
        // (measured 2026-10-21: connect ~8 s, first byte ~9 s, or no answer for 60 s), so a 15 s limit made Live look dead.
        let decoder = HLSFrameSource(source: source, stallTimeout: source.id == requestedHLSID ? 75 : 15, requestPolicy: resourcePolicy(for: source))
        // The camera on screen is sampled ~10x/s for overlay boxes (the detector-only pass takes ~10 ms) (the Hub runs the heavy pass about once a second); background watches stay at 1/s.
        decoder.tapInterval = source.id == requestedHLSID ? 0.1 : 1
        decoder.onStateChange = { [weak self, weak decoder] state in
            guard let self, self.generation == run, !self.blockedIDs.contains(id), self.hlsSources[id] != nil else { return }
            switch state {
            case .connecting: self.sourceStates[id] = .videoConnecting
            case .streaming:
                self.sourceStates[id] = .polling
                if id == self.requestedHLSID { self.setLiveVideoSource(id) }   // the pinned stream is up: let background watches resume
            case .retrying(let reason):
                self.sourceStates[id] = .videoUnavailable(reason)
                if decoder?.isRunning == false { self.hlsSources[id] = nil }
            case .stopped: break
            }
            self.updateStatus()
        }
        hlsSources[id] = decoder
        decoder.start(sink: videoSink)
        // The pinned camera is now connecting: release the background decoders that were started before it (selection was
        // computed while its state was still unset, so they were all allowed).
        if id == requestedHLSID {
            let keep = selectedHLSIDs
            for other in Array(hlsSources.keys) where !keep.contains(other) {
                stopHLS(other)
                if !blockedIDs.contains(other) { sourceStates[other] = watchedIDs.contains(other) ? .videoIdle : nil }
            }
        }
        updateStatus()
    }

    private func stopHLS(_ id: UUID) {
        hlsSources.removeValue(forKey: id)?.stop()
    }
    private func markRobotsBlocked(_ id: UUID, run: UUID) async {
        guard generation == run, !blockedIDs.contains(id),
              let source = catalogue?.sources.first(where: { $0.id == id }) else { return }
        let decision = await robots.decision(for: source.url)
        guard generation == run, !blockedIDs.contains(id) else { return }
        if case .unavailable(let reason) = decision { sourceStates[id] = .policyUnavailable(reason) }
        else { sourceStates[id] = .blockedByRobots }
        updateStatus()
    }
    nonisolated private static func origin(_ url: URL) -> String { "\(url.scheme ?? "https")://\(url.host ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))" }

    private func updateStatus() {
        runningCount = sourceStates.values.filter { $0 == .polling }.count
        let checking = sourceStates.values.filter { $0 == .checking }.count
        let imageFailures = sourceStates.values.filter { if case .imageUnavailable = $0 { true } else { false } }.count
        let videoConnecting = sourceStates.values.filter { $0 == .videoConnecting }.count
        let refused = sourceStates.values.filter { $0 == .blockedByRobots }.count
        let suspended = sourceStates.values.filter { $0 == .suspended }.count
        let unavailable = sourceStates.values.filter { if case .policyUnavailable = $0 { true } else { false } }.count
        var parts: [String] = []
        if runningCount > 0 { parts.append("Polling \(runningCount) watched feed(s)") }
        let idle = (catalogue?.runnable ?? []).filter { !blockedIDs.contains($0.id) && !watchedIDs.contains($0.id) }.count
        if idle > 0 { parts.append("\(idle) confirmed · not watched") }
        if videoConnecting > 0 { parts.append("\(videoConnecting) video connecting") }
        if imageFailures > 0 { parts.append("\(imageFailures) camera images retrying") }
        if checking > 0 { parts.append("\(checking) checking robots.txt") }
        if awaitingTermsCount > 0 { parts.append("\(awaitingTermsCount) awaiting terms") }
        if unavailable > 0 { parts.append("\(unavailable) policy lookups retrying") }
        if refused > 0 { parts.append("\(refused) refused by robots.txt") }
        let locallyBlocked = sourceStates.values.filter { $0 == .blockedByUser }.count
        if locallyBlocked > 0 { parts.append("\(locallyBlocked) blocked locally") }
        if suspended > 0 { parts.append("\(suspended) suspended") }
        if activeVideoCount > 0 || queuedVideoCount > 0 {
            let active = activeVideoCount == 1 ? "1 HLS stream active" : "\(activeVideoCount) HLS streams active"
            let queued = queuedVideoCount == 1 ? "1 queued" : "\(queuedVideoCount) queued"
            parts.append("\(active); \(queued) rotate every minute")
        }
        status = parts.isEmpty ? Self.describe(running: 0, awaiting: 0, total: catalogue?.sources.count ?? 0) : parts.joined(separator: "; ")
    }

    enum PreviewError: Error, LocalizedError {
        case notConfirmed, blockedLocally, badResponse(Int), notAnImage
        case policyUnavailable(String), policyRefused(String), videoUnavailable(String)
        var policyRetryDelay: TimeInterval? {
            if case .policyUnavailable = self { 60 } else { nil }
        }
        var errorDescription: String? {
            switch self {
            case .policyUnavailable(let reason): return "\(reason) Retrying automatically within a minute. Refresh now retries immediately."
            case .policyRefused(let reason): return reason
            case .notConfirmed: return "Terms for this host are not confirmed yet."
            case .blockedLocally: return "Blocked on this Mac. Unblock this camera to view it again."
            case .badResponse(let code): return "The camera answered HTTP \(code). Use ⦸ to block an unavailable camera."
            case .videoUnavailable(let reason): return "Video unavailable: \(reason)"
            case .notAnImage: return "The camera did not return an image. Use ⦸ to block this camera."
            }
        }
    }

    func fetchPreview(of source: PublicFeedSource, retryFailedPolicy: Bool = false) async throws -> Data {
        guard !blockedIDs.contains(source.id) else { throw PreviewError.blockedLocally }
        guard source.mayBeAnalysed else { throw PreviewError.notConfirmed }
        let requestID = UUID(), run = generation
        let task = Task { [weak self, robots, throttle, session] () throws -> Data in
            let decision = await robots.decision(for: source.url, retryFailure: retryFailedPolicy)
            switch decision {
            case .allowed: break
            case .unavailable(let reason): throw PreviewError.policyUnavailable(reason)
            case .disallowed(let reason): throw PreviewError.policyRefused(reason)
            }
            guard await throttle.acquire(host: source.url.host ?? "", interactive: true) else { throw CancellationError() }
            try Task.checkCancellation()
            guard let self, self.mayFetch(source.id, run: run) else { throw PreviewError.blockedLocally }
            switch await robots.decision(for: source.url) {
            case .allowed: break
            case .unavailable(let reason): throw PreviewError.policyUnavailable(reason)
            case .disallowed(let reason): throw PreviewError.policyRefused(reason)
            }
            if retryFailedPolicy {
                self.checkPolicy(for: self.catalogue?.runnable.filter { Self.origin($0.url) == Self.origin(source.url) } ?? [])
            }
            try Task.checkCancellation()
            if source.kind == .hls {
                // No single JPEG exists: pull one decoded frame from the stream for the preview tile.
                let data = try await Self.hlsPreviewFrame(source: source, requestPolicy: self.resourcePolicy(for: source))
                try Task.checkCancellation()
                guard self.mayFetch(source.id, run: run) else { throw PreviewError.blockedLocally }
                return data
            }
            let (data, response) = try await session.data(from: source.url)
            try Task.checkCancellation()
            guard self.mayFetch(source.id, run: run) else { throw PreviewError.blockedLocally }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw PreviewError.badResponse(code) }
            guard data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { throw PreviewError.notAnImage }
            self.noteSnapshot(data, id: source.id)
            if retryFailedPolicy, self.catalogue?.sources.contains(where: { $0.id == source.id }) == true {
                if self.sourceStates[source.id] == .suspended { self.beginPolling(source, run: run) }
                self.recordSnapshotOutcome(.received(Date()), sourceID: source.id, run: run)
            }
            return data
        }
        previewTasks[source.id, default: [:]][requestID] = task
        defer { previewTasks[source.id]?[requestID] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Decode ordinary live HLS without requiring the optional I-frame rendition
    /// needed by AVAssetImageGenerator. The bounded decoder is always released.
    static func hlsPreviewFrame(source: PublicFeedSource, timeout: TimeInterval = 30, requestPolicy: HLSPolicyRelay.Policy? = nil) async throws -> Data {
        guard source.mayBeAnalysed else { throw PreviewError.notConfirmed }
        guard await previewBudget.acquire() else { throw CancellationError() }
        defer { Task { await Self.previewBudget.release() } }
        try Task.checkCancellation()
        let sink = HLSPreviewSink()
        let decoder = HLSFrameSource(source: source, requestPolicy: requestPolicy)
        decoder.start(sink: sink)
        defer { decoder.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(timeout))
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let jpeg = sink.jpeg { return jpeg }
            if case .retrying(let reason) = decoder.state { throw PreviewError.videoUnavailable(reason) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw PreviewError.videoUnavailable("No decoded frame within \(Int(timeout)) seconds. The stream may be offline or require provider access.")
    }

    func stop() {
        generation = UUID()
        hlsRotation?.cancel(); hlsRotation = nil; hlsRotationOffset = 0
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        hostTasks.values.forEach { $0.cancel() }; hostTasks.removeAll()
        previewTasks.values.forEach { $0.values.forEach { $0.cancel() } }; previewTasks.removeAll()
        hlsSources.values.forEach { $0.stop() }; hlsSources.removeAll()
        requestedHLSID = nil
        sourceStates.removeAll(); runningCount = 0; awaitingTermsCount = 0
        lastReceivedAt.removeAll(); contentChangedAt.removeAll(); snapshotDigests.removeAll()
        catalogue = nil; sink = nil; videoSink = nil
        status = "Stopped"
    }

    static func describe(running: Int, awaiting: Int, total: Int) -> String {
        if total == 0 { return "No feeds configured" }
        if running == 0 { return awaiting > 0 ? "\(awaiting) feed(s) awaiting terms confirmation — none polled" : "No feeds polling" }
        return awaiting == 0 ? "Polling \(running) feed(s)" : "Polling \(running) feed(s); \(awaiting) awaiting terms"
    }
}

private struct ClosureSink: FeedFrameSink {
    let handler: @Sendable @MainActor (Data, PublicFeedSource) async -> Void
    init(_ handler: @escaping @Sendable @MainActor (Data, PublicFeedSource) async -> Void) { self.handler = handler }
    func accept(_ frameData: Data, from source: PublicFeedSource) async { await handler(frameData, source) }
}

/// A decoded video frame crossing from a decode queue to the MainActor analysis
/// path. CVPixelBuffer is reference-counted and thread-safe; the box carries the
/// Sendable annotation the pixel-buffer type itself lacks (same precedent as
/// `FramePacket`).
public struct PixelBufferBox: @unchecked Sendable {
    public let buffer: CVPixelBuffer
    public init(_ buffer: CVPixelBuffer) { self.buffer = buffer }
}

/// Adapts `HLSFrameSource`'s `LiveFrameSink` to the runner's video handler.
private struct ClosureVideoSink: LiveFrameSink {
    let handler: @Sendable @MainActor (PixelBufferBox, PublicFeedSource) async -> Void
    func accept(_ pixelBuffer: CVPixelBuffer, from source: PublicFeedSource) async {
        await handler(PixelBufferBox(pixelBuffer), source)
    }
}


@MainActor
private final class HLSPreviewSink: LiveFrameSink {
    private(set) var jpeg: Data?
    nonisolated func accept(_ pixelBuffer: CVPixelBuffer, from source: PublicFeedSource) async {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scale = min(1, 640 / max(ci.extent.width, ci.extent.height))
        let fitted = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let context = CIContext()
        guard let image = context.createCGImage(fitted, from: fitted.extent),
              let bytes = NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.7]) else { return }
        await store(bytes)
    }
    private func store(_ data: Data) { if jpeg == nil { jpeg = data } }
}
