import FeedIngest
import Foundation

/// Polls the Hub's confirmed public feeds. One task per source; each source is fetched through
/// `FeedIngest.SnapshotPoller`, which honours the refresh-interval floor, single-flight, exponential back-off and
/// suspension after repeated failures, and **refuses to contact a source whose terms no person confirmed**
/// (`PublicFeedSource.mayBeAnalysed`). Frames are handed straight to the analysis closure and never written to disk.
@MainActor
final class FeedRunner: ObservableObject {
    @Published private(set) var status = "No feeds configured"
    @Published private(set) var runningCount = 0
    @Published private(set) var awaitingTermsCount = 0

    /// Identifies us to the operators of the feeds we poll, with where to reach us.
    static let userAgent = "PlateWatchHub/0.1 (+https://github.com/noktirnal42/PlateWatch; public-feed accountability research)"

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.ephemeral          // no cookies, no cache: nothing is retained
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 20
        config.waitsForConnectivity = false
        config.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
        self.session = URLSession(configuration: config)
    }

    func start(catalogue: FeedCatalogue,
               analyse: @escaping @Sendable @MainActor (Data, PublicFeedSource) async -> Void) {
        stop()
        awaitingTermsCount = catalogue.awaitingTerms.count
        let sink = ClosureSink(analyse)
        for source in catalogue.runnable {
            let poller = SnapshotPoller(source: source, sink: sink, session: session)
            tasks[source.id] = Task { await poller.run(sink: sink) }
        }
        runningCount = tasks.count
        status = Self.describe(running: runningCount, awaiting: awaitingTermsCount, total: catalogue.sources.count)
    }

    func stop() {
        tasks.values.forEach { $0.cancel() }
        tasks.removeAll()
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
