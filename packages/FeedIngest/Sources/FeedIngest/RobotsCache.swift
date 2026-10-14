import Foundation

/// Actor that caches robots.txt policies per host and decides fetch permission.
public actor RobotsCache {
    private let session: URLSession
    private let userAgent: String
    private let ttl: TimeInterval
    private let failureTTL: TimeInterval = 600 // 10 minutes for 5xx/network errors
    private let now: @Sendable () -> Date
    private let publicAPIPermissions: [PublicAPIPermission]
    private let maxBodySize: Int = 500 * 1024 // 500 KiB

    // Cache entries
    private var cache: [String: CacheEntry] = [:]
    // In-flight fetch tasks to deduplicate
    private var inFlight: [String: Task<CachedPolicy, Error>] = [:]

    private struct CacheEntry {
        let policy: CachedPolicy
        let expiresAt: Date
    }

    private struct CachedPolicy {
        let policy: RobotsPolicy
        let isFailure: Bool // true if cached failure (disallow all, except a scoped operator grant)
        var serverErrorStatus: Int? = nil
    }

    /// Initialize the cache.
    /// - Parameters:
    ///   - session: URLSession to use for fetching robots.txt.
    ///   - userAgent: Our user-agent product token.
    ///   - ttl: Time-to-live for successful cached policies (default 24 hours).
    ///   - now: Injectable clock for testing.
    public init(
        session: URLSession,
        userAgent: String,
        ttl: TimeInterval = 86_400,
        publicAPIPermissions: [PublicAPIPermission] = [],
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.userAgent = userAgent
        self.ttl = ttl
        self.now = now
        self.publicAPIPermissions = publicAPIPermissions
    }

    /// Check if a URL is allowed per robots.txt.
    /// Fetches and caches robots.txt for the host if not cached or expired.
    /// - Parameter url: The URL to check.
    /// - Returns: true if allowed, false if disallowed.
    public func isAllowed(_ url: URL) async -> Bool {
        guard let host = url.host else { return false }
        let port = url.port ?? (url.scheme == "https" ? 443 : 80)
        let cacheKey = "\(url.scheme ?? "https")://\(host):\(port)"

        let currentTime = now()

        // Check cache
        if let entry = cache[cacheKey], entry.expiresAt > currentTime {
            return permission(entry.policy, for: url)
        }

        // Check for in-flight fetch
        if let task = inFlight[cacheKey] {
            do {
                let result = try await task.value
                return permission(result, for: url)
            } catch {
                // Task failed, treat as disallow
                return false
            }
        }

        // Start new fetch
        let task = Task<CachedPolicy, Error> { [session, userAgent, maxBodySize] in
            let robotsURL = URL(string: "\(cacheKey)/robots.txt")!
            var request = URLRequest(url: robotsURL)
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

            do {
                let (data, response) = try await session.data(for: request)
                guard let httpResponse = response as? HTTPURLResponse else {
                    throw URLError(.badServerResponse)
                }

                let statusCode = httpResponse.statusCode

                // Cap body size
                let bodyData = data.count > maxBodySize ? data.prefix(maxBodySize) : data
                let body = (String(data: bodyData, encoding: .utf8) ?? "").replacingOccurrences(of: "\u{FEFF}", with: "")

                switch statusCode {
                case 200..<300:
                    // Some SPA/parked hosts return their HTML homepage with 200 for every path.
                    // That is not a successful robots policy fetch; retry later instead of silently allowing it.
                    let mime = httpResponse.value(forHTTPHeaderField: "Content-Type")?.lowercased() ?? ""
                    guard !mime.contains("text/html"),
                          !body.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<") else {
                        throw URLError(.cannotParseResponse)
                    }
                    let policy = RobotsPolicy(parsing: body, userAgent: userAgent)
                    return CachedPolicy(policy: policy, isFailure: false)
                case 403 where Self.isObjectStoreMissingKey(httpResponse, body: body):
                    // An S3-backed host (CloudFront/S3) answers a request for a file that does not exist with
                    // 403 AccessDenied (the bucket denies listing, so "missing" and "forbidden" look the same).
                    // That is "no robots.txt", not a refusal. Deliberately narrow: only an AmazonS3 server with the
                    // S3 AccessDenied error document; every other 401/403/429 still stops us.
                    return CachedPolicy(policy: .allowAll, isFailure: false)
                case 401, 403, 429:
                    // RFC 9309 treats any 4xx as "no robots.txt" (allow), but for these three the host is telling us it is
                    // refusing or rate-limiting us: our politeness rule is to stop and flag, not to carry on
                    // (docs/FEED-SOURCES.md §6b). Cached as a failure, so we retry in 10 minutes, not every poll.
                    throw URLError(.userAuthenticationRequired)
                case 400..<500:
                    // Other 4xx (404 and friends): no robots.txt, allow all
                    return CachedPolicy(policy: .allowAll, isFailure: false)
                case 500...599:
                    // Cache the HTTP status so a cited, origin/path-scoped operator grant can be evaluated per URL.
                    return CachedPolicy(policy: .disallowAll, isFailure: true, serverErrorStatus: statusCode)
                default:
                    throw URLError(.badServerResponse)
                }
            } catch {
                // Network error, timeout, 5xx: disallow all
                throw error
            }
        }

        inFlight[cacheKey] = task

        do {
            let result = try await task.value
            let expiresAt = now().addingTimeInterval(result.isFailure ? failureTTL : ttl)
            cache[cacheKey] = CacheEntry(policy: result, expiresAt: expiresAt)
            inFlight[cacheKey] = nil
            return permission(result, for: url)
        } catch {
            // Cache failure for 10 minutes
            let failurePolicy = CachedPolicy(policy: .disallowAll, isFailure: true)
            let expiresAt = now().addingTimeInterval(failureTTL)
            cache[cacheKey] = CacheEntry(policy: failurePolicy, expiresAt: expiresAt)
            inFlight[cacheKey] = nil
            return false
        }
    }

    private func permission(_ cached: CachedPolicy, for url: URL) -> Bool {
        if cached.policy.isAllowed(path: pathAndQuery(from: url)) { return true }
        guard let code = cached.serverErrorStatus else { return false }
        return publicAPIPermissions.contains { $0.allows(url, robotsHTTPStatus: code) }
    }

    static func isObjectStoreMissingKey(_ response: HTTPURLResponse, body: String) -> Bool {
        (response.value(forHTTPHeaderField: "Server") ?? "").localizedCaseInsensitiveContains("AmazonS3")
            && body.contains("<Code>AccessDenied</Code>")
    }

    private func pathAndQuery(from url: URL) -> String {
        var path = url.path
        if path.isEmpty { path = "/" }
        if let query = url.query, !query.isEmpty {
            path += "?\(query)"
        }
        return path
    }
}