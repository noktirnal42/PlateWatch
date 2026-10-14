import FeedIngest
import Foundation
import SwiftUI

/// Polls the Hub's confirmed public feeds. One task per source; each source is fetched through
/// `FeedIngest.SnapshotPoller`, which honours the refresh-interval floor, single-flight, exponential back-off and
/// suspension after repeated failures, and **refuses to contact a source whose terms no person confirmed**
/// (`PublicFeedSource.mayBeAnalysed`). Frames are handed straight to the analysis closure and never written to disk.
/// One shared pacing queue per host: however many cameras a host serves, we send it at most one request per `interval`.
/// (822 Austin cameras on one image host must not become 822 simultaneous requests.)
actor HostThrottle {
    private let interval: TimeInterval
    private var nextSlot: [String: Date] = [:]
    init(interval: TimeInterval = 1.0) { self.interval = interval }

    func acquire(host: String) async {
        let now = Date()
        let slot = max(now, nextSlot[host] ?? now)
        nextSlot[host] = slot.addingTimeInterval(interval)
        let wait = slot.timeIntervalSince(now)
        if wait > 0 { try? await Task.sleep(for: .seconds(wait)) }
    }
}

@MainActor
final class FeedRunner: ObservableObject {
    @Published private(set) var status = "No feeds configured"
    @Published private(set) var runningCount = 0
    @Published private(set) var awaitingTermsCount = 0

    /// Identifies us to the operators of the feeds we poll, with where to reach us.
    static let userAgent = "PlateWatchHub/0.1 (+https://github.com/noktirnal42/PlateWatch; public-feed accountability research)"

    /// What happened to each source the runner started. Sources not in the map were never started (awaiting terms).
    enum SourceState: Equatable { case polling, blockedByRobots, suspended }
    @Published private(set) var sourceStates: [UUID: SourceState] = [:]

    enum StatusKind: String, CaseIterable, Identifiable {
        case polling = "Polling", confirmed = "Confirmed (idle)", awaiting = "Awaiting terms"
        case blocked = "Blocked / refused", suspended = "Suspended"
        var id: String { rawValue }
    }
    struct Display { let text: String; let icon: String; let color: Color; let kind: StatusKind }
    func state(of source: PublicFeedSource) -> Display {
        guard source.mayBeAnalysed else { return .init(text: "Awaiting terms", icon: "hourglass", color: .orange, kind: .awaiting) }
        switch sourceStates[source.id] {
        case .polling: return .init(text: "Polling", icon: "checkmark.circle.fill", color: .green, kind: .polling)
        case .blockedByRobots: return .init(text: "Blocked by robots.txt / refused", icon: "hand.raised.fill", color: .red, kind: .blocked)
        case .suspended: return .init(text: "Suspended after repeated failures", icon: "exclamationmark.triangle.fill", color: .yellow, kind: .suspended)
        case nil: return .init(text: "Confirmed", icon: "checkmark.circle", color: .secondary, kind: .confirmed)
        }
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let session: URLSession
    /// robots.txt per host (24 h cache; 401/403/429/5xx/network error ⇒ treated as "do not fetch" for 10 minutes).
    private let robots: RobotsCache
    private let throttle = HostThrottle()
    private let previewThrottle = HostThrottle(interval: 1.0)

    init() {
        let config = URLSessionConfiguration.ephemeral          // no cookies, no cache: nothing is retained
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: config)
        self.robots = RobotsCache(session: session, userAgent: Self.userAgent)
    }

    func start(catalogue: FeedCatalogue,
               analyse: @escaping @Sendable @MainActor (Data, PublicFeedSource) async -> Void) {
        stop()
        awaitingTermsCount = catalogue.awaitingTerms.count
        let sink = ClosureSink(analyse)
        for source in catalogue.runnable {
            let robots = self.robots
            let throttle = self.throttle
            let id = source.id
            sourceStates[id] = .polling
            let poller = SnapshotPoller(source: source, sink: sink, session: session,
                                        gate: { url in
                                            await throttle.acquire(host: url.host ?? "")
                                            let allowed = await robots.isAllowed(url)
                                            if !allowed { await MainActor.run { self.sourceStates[id] = .blockedByRobots } }
                                            return allowed
                                        })
            tasks[source.id] = Task {
                await poller.run(sink: sink)
                // `run` returns on its own only when robots refused (already recorded) or the source was suspended.
                await MainActor.run {
                    if !Task.isCancelled, self.sourceStates[id] == .polling { self.sourceStates[id] = .suspended }
                }
            }
        }
        runningCount = tasks.count
        status = Self.describe(running: runningCount, awaiting: awaitingTermsCount, total: catalogue.sources.count)
    }

    enum PreviewError: Error, LocalizedError {
        case notConfirmed, blocked, badResponse(Int), notAnImage
        var errorDescription: String? {
            switch self {
            case .notConfirmed: return "Terms for this host are not confirmed yet."
            case .blocked: return "The host's robots.txt (or a 401/403/429 on it) says not to fetch."
            case .badResponse(let c): return "The camera answered HTTP \(c)."
            case .notAnImage: return "The camera did not return an image."
            }
        }
    }

    /// One on-demand look at a camera for the console viewer. Same rules as polling: only confirmed sources, robots.txt
    /// first, our identifying User-Agent. The image is returned to the caller and not stored.
    func fetchPreview(of source: PublicFeedSource) async throws -> Data {
        guard source.mayBeAnalysed else { throw PreviewError.notConfirmed }
        // A person is looking at this camera: it does not wait behind the polling queue, but is still paced (one preview
        // request per host per second, its own queue) so previews can never become a second poller.
        await previewThrottle.acquire(host: source.url.host ?? "")
        guard await robots.isAllowed(source.url) else { throw PreviewError.blocked }
        let (data, response) = try await session.data(from: source.url)
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(code) else { throw PreviewError.badResponse(code) }
        guard data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50]) else { throw PreviewError.notAnImage }
        return data
    }

    func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
        sourceStates.removeAll()
        runningCount = 0
    }

    static func describe(running: Int, awaiting: Int, total: Int) -> String {
        if total == 0 { return "No feeds configured" }
        if running == 0 { return "\(awaiting) feed(s) awaiting terms confirmation — none polled" }
        return awaiting == 0 ? "Polling \(running) feed(s)" : "Polling \(running) feed(s); \(awaiting) awaiting terms"
    }
}

private struct ClosureSink: FeedFrameSink {
    let handler: @Sendable @MainActor (Data, PublicFeedSource) async -> Void
    init(_ handler: @escaping @Sendable @MainActor (Data, PublicFeedSource) async -> Void) { self.handler = handler }
    func accept(_ frameData: Data, from source: PublicFeedSource) async { await handler(frameData, source) }
}
