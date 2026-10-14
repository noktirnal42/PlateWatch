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
        case checking, polling, blockedByRobots, blockedByUser, suspended
        case policyUnavailable(String)
    }
    @Published private(set) var sourceStates: [UUID: SourceState] = [:]
    enum StatusKind: String, CaseIterable, Identifiable {
        case checking = "Checking robots.txt", polling = "Polling", confirmed = "Confirmed (idle)"
        case unavailable = "Policy temporarily unavailable"
        case awaiting = "Awaiting terms", blocked = "Blocked / refused", userBlocked = "Blocked by you", suspended = "Suspended"
        var id: String { rawValue }
    }
    struct Display { let text: String; let icon: String; let color: Color; let kind: StatusKind }
    func state(of source: PublicFeedSource) -> Display {
        if blockedIDs.contains(source.id) { return .init(text: "Blocked on this Mac", icon: "nosign", color: .secondary, kind: .userBlocked) }
        guard source.mayBeAnalysed else { return .init(text: "Awaiting terms", icon: "hourglass", color: .orange, kind: .awaiting) }
        switch sourceStates[source.id] {
        case .checking: return .init(text: "Checking robots.txt…", icon: "clock", color: .secondary, kind: .checking)
        case .polling: return .init(text: "Polling", icon: "checkmark.circle.fill", color: .green, kind: .polling)
        case .policyUnavailable: return .init(text: "Policy temporarily unavailable", icon: "arrow.clockwise", color: .orange, kind: .unavailable)
        case .blockedByRobots: return .init(text: "Host policy refused", icon: "hand.raised.fill", color: .red, kind: .blocked)
        case .blockedByUser: return .init(text: "Blocked on this Mac", icon: "nosign", color: .secondary, kind: .userBlocked)
        case .suspended: return .init(text: "Suspended after repeated failures", icon: "exclamationmark.triangle.fill", color: .orange, kind: .suspended)
        case nil: return .init(text: "Confirmed (idle)", icon: "checkmark.circle", color: .secondary, kind: .confirmed)
        }
    }

    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var hostTasks: [String: Task<Void, Never>] = [:]
    private var previewTasks: [UUID: [UUID: Task<Data, Error>]] = [:]
    private var generation = UUID()
    private var catalogue: FeedCatalogue?
    private var sink: ClosureSink?
    private var blockedIDs: Set<UUID> = []
    private let session: URLSession
    private let robots: RobotsCache
    private let throttle: HostThrottle
    private let retryInterval: Duration

    init(session: URLSession? = nil, throttleInterval: TimeInterval = 1, retryInterval: Duration = .seconds(60), publicAPIPermissions: [PublicAPIPermission] = [.caltransCCTV]) {
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

    func start(catalogue: FeedCatalogue, blockedIDs: Set<UUID> = [],
               analyse: @escaping @Sendable @MainActor (Data, PublicFeedSource) async -> Void) {
        stop()
        self.catalogue = catalogue
        let run = generation
        self.sink = ClosureSink { [weak self] data, source in
            guard let self, self.mayFetch(source.id, run: run), !Task.isCancelled else { return }
            await analyse(data, source)
        }
        self.blockedIDs = blockedIDs
        awaitingTermsCount = catalogue.awaitingTerms.filter { !blockedIDs.contains($0.id) }.count
        sourceStates = Dictionary(uniqueKeysWithValues: catalogue.sources.compactMap { source in
            if blockedIDs.contains(source.id) { return (source.id, .blockedByUser) }
            return source.mayBeAnalysed ? (source.id, .checking) : nil
        })
        for sources in Dictionary(grouping: catalogue.runnable, by: { Self.origin($0.url) }).values {
            checkPolicy(for: sources)
        }
        updateStatus()
    }

    /// Cancel just this camera, including in-flight previews. Unblock rechecks policy without restarting every other camera.
    func setBlocked(_ id: UUID, blocked: Bool) {
        if blocked {
            blockedIDs.insert(id)
            tasks.removeValue(forKey: id)?.cancel()
            previewTasks.removeValue(forKey: id)?.values.forEach { $0.cancel() }
            sourceStates[id] = .blockedByUser
        } else {
            blockedIDs.remove(id)
            sourceStates[id] = nil
            if let source = catalogue?.sources.first(where: { $0.id == id }), source.mayBeAnalysed {
                sourceStates[id] = .checking
                checkPolicy(for: catalogue?.runnable.filter { Self.origin($0.url) == Self.origin(source.url) } ?? [])
            }
        }
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
                let pending = sources.filter { !self.blockedIDs.contains($0.id) && self.tasks[$0.id] == nil && self.sourceStates[$0.id] != .suspended }
                var decisions: [UUID: RobotsDecision] = [:]
                for source in pending {
                    decisions[source.id] = await self.robots.decision(for: source.url)
                    guard !Task.isCancelled, self.generation == run else { return }
                }
                for source in pending where !self.blockedIDs.contains(source.id) {
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
        guard let sink, tasks[source.id] == nil, !blockedIDs.contains(source.id) else { return }
        guard source.kind == .snapshotJPEG else {
            sourceStates[source.id] = .suspended
            return
        }
        let id = source.id, robots = self.robots, throttle = self.throttle
        sourceStates[id] = .polling
        let poller = SnapshotPoller(source: source, sink: sink, session: session, gate: { [weak self] url in
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
            if self.sourceStates[id] == .polling { self.sourceStates[id] = .suspended }
            self.updateStatus()
        }
    }

    private func mayFetch(_ id: UUID, run: UUID) -> Bool { generation == run && !blockedIDs.contains(id) }
    private func markRobotsBlocked(_ id: UUID, run: UUID) async {
        guard generation == run, !blockedIDs.contains(id),
              let source = catalogue?.sources.first(where: { $0.id == id }) else { return }
        let decision = await robots.decision(for: source.url)
        guard generation == run, !blockedIDs.contains(id) else { return }
        if case .unavailable(let reason) = decision { sourceStates[id] = .policyUnavailable(reason) }
        else { sourceStates[id] = .blockedByRobots }
        updateStatus()
    }
    private static func origin(_ url: URL) -> String { "\(url.scheme ?? "https")://\(url.host ?? ""):\(url.port ?? (url.scheme == "https" ? 443 : 80))" }

    private func updateStatus() {
        runningCount = sourceStates.values.filter { $0 == .polling }.count
        let checking = sourceStates.values.filter { $0 == .checking }.count
        let refused = sourceStates.values.filter { $0 == .blockedByRobots }.count
        let suspended = sourceStates.values.filter { $0 == .suspended }.count
        let unavailable = sourceStates.values.filter { if case .policyUnavailable = $0 { true } else { false } }.count
        var parts: [String] = []
        if runningCount > 0 { parts.append("Polling \(runningCount) feed(s)") }
        if checking > 0 { parts.append("\(checking) checking robots.txt") }
        if awaitingTermsCount > 0 { parts.append("\(awaitingTermsCount) awaiting terms") }
        if unavailable > 0 { parts.append("\(unavailable) policy lookups retrying") }
        if refused > 0 { parts.append("\(refused) refused by robots.txt") }
        let locallyBlocked = sourceStates.values.filter { $0 == .blockedByUser }.count
        if locallyBlocked > 0 { parts.append("\(locallyBlocked) blocked locally") }
        if suspended > 0 { parts.append("\(suspended) suspended") }
        status = parts.isEmpty ? Self.describe(running: 0, awaiting: 0, total: catalogue?.sources.count ?? 0) : parts.joined(separator: "; ")
    }

    enum PreviewError: Error, LocalizedError {
        case notConfirmed, blockedLocally, badResponse(Int), notAnImage
        case policyUnavailable(String), policyRefused(String)
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
            let (data, response) = try await session.data(from: source.url)
            try Task.checkCancellation()
            guard self.mayFetch(source.id, run: run) else { throw PreviewError.blockedLocally }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { throw PreviewError.badResponse(code) }
            guard data.starts(with: [0xFF, 0xD8]) || data.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { throw PreviewError.notAnImage }
            return data
        }
        previewTasks[source.id, default: [:]][requestID] = task
        defer { previewTasks[source.id]?[requestID] = nil }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    func stop() {
        generation = UUID()
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        hostTasks.values.forEach { $0.cancel() }; hostTasks.removeAll()
        previewTasks.values.forEach { $0.values.forEach { $0.cancel() } }; previewTasks.removeAll()
        sourceStates.removeAll(); runningCount = 0; awaitingTermsCount = 0
        catalogue = nil; sink = nil
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
