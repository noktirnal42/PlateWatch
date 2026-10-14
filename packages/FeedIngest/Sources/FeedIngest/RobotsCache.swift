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

    /// Manual retry invalidates only an unavailable lookup, never a valid Disallow/authentication/rate refusal.
    public func decision(for url: URL, retryFailure: Bool = false) async -> RobotsDecision {
        guard let host = url.host else { return .unavailable("Invalid camera host.") }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let origin = "\(url.scheme ?? "https")://\(host):\(port)"
        if let entry = cache[origin], entry.expiresAt > now() {
            let result = permission(entry.policy, for: url)
            if retryFailure, case .unavailable = result { cache[origin] = nil }
            else { return result }
        }
        if let task = inFlight[origin] { return permission(await task.value, for: url) }

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
                    case .timedOut: reason = "robots.txt request timed out."
                    case .notConnectedToInternet, .networkConnectionLost: reason = "Network connection unavailable during robots.txt lookup."
                    case .cannotFindHost, .dnsLookupFailed: reason = "Could not resolve the robots.txt host."
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
        return permission(result, for: url)
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
