import Foundation
import PlateKit

/// Fetches public snapshot-JPEG feeds on a `FeedSchedule` and hands decoded
/// bytes to a `FeedFrameSink`. Single-flight per source, refresh-interval
/// floor honored, exponential backoff on failure, suspension after repeated
/// failures (docs/CAMERA-SOURCES.md — politeness is a requirement, not a
/// nicety: these are somebody else's public endpoints).
public struct SnapshotPoller: Sendable {
    public let source: PublicFeedSource
    private let session: URLSession
    private let sink: FeedFrameSink
    /// When true (the default) nothing is fetched unless `source.mayBeAnalysed` — a person confirmed the feed's
    /// terms (docs/FEED-SOURCES.md §5). Public *viewing* is not a licence to analyse.
    public let enforceTerms: Bool
    /// Optional extra permission check run before **every** fetch cycle (e.g. `RobotsCache.isAllowed`). When it says no,
    /// the poller stops: it never contacts a URL it was told not to fetch, and picks up policy changes within the cache TTL.
    public typealias FetchGate = @Sendable (URL) async -> Bool
    private let gate: FetchGate?

    /// True when this poller is allowed to contact the source at all.
    public var isPermitted: Bool { !enforceTerms || source.mayBeAnalysed }

    public init(source: PublicFeedSource, sink: FeedFrameSink, session: URLSession? = nil,
                enforceTerms: Bool = true, gate: FetchGate? = nil) {
        self.source = source
        self.sink = sink
        self.enforceTerms = enforceTerms
        self.gate = gate
        self.session = session ?? {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 10
            config.timeoutIntervalForResource = 20
            config.waitsForConnectivity = false
            return URLSession(configuration: config)
        }()
    }

    /// One fetch cycle: due-check → fetch → sink → schedule update.
    /// Returns the updated schedule so a driver loop can persist it.
    public func pollOnce(schedule: inout FeedSchedule, now: Date = Date()) async -> FeedSchedule {
        guard isPermitted else { return schedule }          // no request is made for an unconfirmed source
        guard !schedule.isSuspended, schedule.isDue(now) else { return schedule }
        do {
            let (data, response) = try await session.data(from: source.url)
            guard let http = response as? HTTPURLResponse else {
                throw URLError(.badServerResponse)
            }
            guard (200..<300).contains(http.statusCode) else {
                throw URLError(.badServerResponse)
            }
            // A snapshot feed must at least look like an image; refuse to
            // feed HTML error pages into the pipeline.
            let type = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            guard type.isEmpty || type.contains("image") || data.starts(with: [0xFF, 0xD8]) else {
                throw URLError(.cannotDecodeContentData)
            }
            await sink.accept(data, from: source)
            schedule.recordSuccess(now: now)
        } catch {
            schedule.recordFailure(now: now)
        }
        return schedule
    }

    /// Driver loop: polls until cancelled, one source, sequential cycles.
    /// `Task cancellation` stops at the next cycle boundary — no dangling
    /// requests beyond the session timeouts.
    public func run(sink: FeedFrameSink) async {
        guard isPermitted else { return }
        var schedule = FeedSchedule(refreshInterval: source.refreshInterval)
        while !Task.isCancelled {
            if let gate, !(await gate(source.url)) { return }      // robots.txt (or another policy) says stop
            schedule = await pollOnce(schedule: &schedule)
            if schedule.isSuspended { return }
            let sleepFor = max(0, schedule.nextFetchAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(sleepFor))
        }
    }
}
