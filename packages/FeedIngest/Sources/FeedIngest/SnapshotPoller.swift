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

    public init(source: PublicFeedSource, sink: FeedFrameSink, session: URLSession? = nil) {
        self.source = source
        self.sink = sink
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
            schedule.recordSuccess(now: Date())
        } catch {
            schedule.recordFailure(now: Date())
        }
        return schedule
    }

    /// Driver loop: polls until cancelled, one source, sequential cycles.
    /// `Task cancellation` stops at the next cycle boundary — no dangling
    /// requests beyond the session timeouts.
    public func run(sink: FeedFrameSink) async {
        var schedule = FeedSchedule(refreshInterval: source.refreshInterval)
        while !Task.isCancelled {
            schedule = await pollOnce(schedule: &schedule)
            if schedule.isSuspended { return }
            let sleepFor = max(0, schedule.nextFetchAt.timeIntervalSinceNow)
            try? await Task.sleep(for: .seconds(sleepFor))
        }
    }
}
