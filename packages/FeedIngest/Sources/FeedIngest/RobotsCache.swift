import Foundation

/// A policy refusal and a failed policy lookup are different operational states.
public enum RobotsDecision: Sendable, Equatable {
    case allowed
    case disallowed(String)
    case unavailable(String)

    public var isAllowed: Bool { if case .allowed = self { true } else { false } }
}

/// Origin-scoped policy cache with shared retries, precise diagnostics and fail-closed recovery.
public actor RobotsCache {
    private let session: URLSession
    private let userAgent: String
    private let ttl: TimeInterval
    private let now: @Sendable () -> Date
    private let publicAPIPermissions: [PublicAPIPermission]
    private let maximumAttempts: Int
    private let retryDelay: Duration
    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<CachedPolicy, Never>] = [:]

    private struct CacheEntry { let policy: CachedPolicy; let expiresAt: Date }
    private struct CachedPolicy: Sendable {
        var policy: RobotsPolicy = .disallowAll
        var serverErrorStatus: Int?
        var refusalStatus: Int?
        var failure: String?
    }

    public init(session: URLSession, userAgent: String, ttl: TimeInterval = 86_400,
                publicAPIPermissions: [PublicAPIPermission] = [], maximumAttempts: Int = 3,
                retryDelay: Duration = .seconds(1), now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session; self.userAgent = userAgent; self.ttl = ttl; self.now = now
        self.publicAPIPermissions = publicAPIPermissions
        self.maximumAttempts = min(3, max(1, maximumAttempts)); self.retryDelay = retryDelay
    }

    public func isAllowed(_ url: URL) async -> Bool { await decision(for: url).isAllowed }

    /// Take one policy snapshot per origin for the batch, then evaluate every camera path.
    /// Even a large or slow batch must not refetch an expired failure halfway through the same host.
    public func decisions(for urls: [URL]) async -> [RobotsDecision] {
        var policies: [String: CachedPolicy] = [:]
        var out: [RobotsDecision] = []
        out.reserveCapacity(urls.count)
        for url in urls {
            guard let host = url.host else { out.append(.unavailable("Invalid camera host.")); continue }
            let origin = "\(url.scheme ?? "https")://\(host):\(url.port ?? (url.scheme == "https" ? 443 : 80))"
            let policy: CachedPolicy
            if let existing = policies[origin] { policy = existing }
            else {
                policy = await lookup(for: url)
                policies[origin] = policy
            }
            out.append(permission(policy, for: url))
        }
        return out
    }

    /// Manual retry invalidates only an unavailable lookup, never a valid Disallow/authentication/rate refusal.
    public func decision(for url: URL, retryFailure: Bool = false) async -> RobotsDecision {
        permission(await lookup(for: url, retryFailure: retryFailure), for: url)
    }

    private func lookup(for url: URL, retryFailure: Bool = false) async -> CachedPolicy {
        guard let host = url.host else { return CachedPolicy(failure: "Invalid camera host.") }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let origin = "\(url.scheme ?? "https")://\(host):\(port)"
        if let entry = cache[origin], entry.expiresAt > now() {
            let result = permission(entry.policy, for: url)
            if retryFailure, case .unavailable = result { cache[origin] = nil }
            else { return entry.policy }
        }
        if let task = inFlight[origin] { return await task.value }

        let task = Task { [session, userAgent, maximumAttempts, retryDelay, publicAPIPermissions] in
            var last = CachedPolicy(failure: "Policy request did not complete.")
            for attempt in 0..<maximumAttempts {
                if attempt > 0 {
                    do { try await Task.sleep(for: retryDelay * attempt) }
                    catch { return last }
                }
                var request = URLRequest(url: URL(string: "\(origin)/robots.txt")!, cachePolicy: .reloadIgnoringLocalCacheData,
                                         timeoutInterval: 15)
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                do {
                    let (data, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
                    let code = http.statusCode
                    let body = (String(data: data.prefix(500 * 1024), encoding: .utf8) ?? "")
                        .replacingOccurrences(of: "\u{FEFF}", with: "")
                    switch code {
                    case 200..<300:
                        let mime = http.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                        guard !mime.contains("text/html"), !body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
                            last = .init(failure: "robots.txt returned an HTML page instead of a policy (HTTP \(code)).")
                            continue
                        }
                        return CachedPolicy(policy: RobotsPolicy(parsing: body, userAgent: userAgent))
                    case 403 where Self.isObjectStoreMissingKey(http, body: body):
                        return CachedPolicy(policy: .allowAll)
                    case 401, 403, 429:
                        return CachedPolicy(refusalStatus: code)
                    case 400..<500:
                        return CachedPolicy(policy: .allowAll)
                    case 500...599:
                        last = CachedPolicy(serverErrorStatus: code, failure: "robots.txt answered HTTP \(code).")
                        if publicAPIPermissions.contains(where: { $0.allows(url, robotsHTTPStatus: code) }) { return last }
                    default:
                        last = CachedPolicy(failure: "Unexpected robots.txt response (HTTP \(code)).")
                    }
                } catch {
                    let code = (error as? URLError)?.code
                    if code == .cancelled { return CachedPolicy(failure: "Policy request cancelled.") }
                    let reason: String
                    switch code {
                    case .timedOut:
                        reason = "Connection to \(url.host ?? "camera host") timed out during the policy lookup. No robots refusal was received; the camera host may also be unreachable."
                    case .notConnectedToInternet, .networkConnectionLost: reason = "Network connection unavailable during robots.txt lookup."
                    case .cannotFindHost, .dnsLookupFailed: reason = "Could not resolve \(url.host ?? "camera host") for the policy lookup. Camera images on this host may also be unavailable."
                    case .cannotConnectToHost: reason = "Could not connect to \(url.host ?? "camera host") for the policy lookup. No robots refusal was received."
                    case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                         .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid:
                        reason = "The robots.txt host's TLS certificate could not be verified."
                    default: reason = "robots.txt lookup failed: \(error.localizedDescription)"
                    }
                    last = CachedPolicy(failure: reason)
                }
            }
            return last
        }
        inFlight[origin] = task
        let result = await task.value
        // Transient failures recover within one minute. Authentication/rate refusals retain a polite ten-minute backoff.
        let lifetime = result.refusalStatus != nil ? 600 : (result.failure != nil ? 60 : ttl)
        cache[origin] = .init(policy: result, expiresAt: now().addingTimeInterval(lifetime))
        inFlight[origin] = nil
        return result
    }

    private func permission(_ cached: CachedPolicy, for url: URL) -> RobotsDecision {
        let path = (url.path.isEmpty ? "/" : url.path) + (url.query.map { "?\($0)" } ?? "")
        if cached.policy.isAllowed(path: path) { return .allowed }
        if let code = cached.serverErrorStatus,
           publicAPIPermissions.contains(where: { $0.allows(url, robotsHTTPStatus: code) }) { return .allowed }
        if let code = cached.refusalStatus { return .disallowed("robots.txt answered HTTP \(code); the host refused or rate-limited access.") }
        if let failure = cached.failure { return .unavailable(failure) }
        return .disallowed("robots.txt disallows this camera path.")
    }

    static func isObjectStoreMissingKey(_ response: HTTPURLResponse, body: String) -> Bool {
        (response.value(forHTTPHeaderField: "Server") ?? "").localizedCaseInsensitiveContains("AmazonS3")
            && body.contains("<Code>AccessDenied</Code>")
    }
}
