import Foundation

/// Actor that caches robots.txt policies per host and decides fetch permission.
public actor RobotsCache {
    private let session: URLSession
    private let userAgent: String
    private let ttl: TimeInterval
    private let failureTTL: TimeInterval = 600 // 10 minutes for 5xx/network errors
    private let now: @Sendable () -> Date
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
        let isFailure: Bool // true if cached failure (disallow all)
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
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.session = session
        self.userAgent = userAgent
        self.ttl = ttl
        self.now = now
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
            return entry.policy.policy.isAllowed(path: pathAndQuery(from: url))
        }

        // Check for in-flight fetch
        if let task = inFlight[cacheKey] {
            do {
                let result = try await task.value
                return result.policy.isAllowed(path: pathAndQuery(from: url))
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
                let body = String(data: bodyData, encoding: .utf8) ?? ""

                switch statusCode {
                case 200..<300:
                    // Parse robots.txt
                    let policy = RobotsPolicy(parsing: body, userAgent: userAgent)
                    return CachedPolicy(policy: policy, isFailure: false)
                case 400..<500:
                    // 4xx means allow all
                    return CachedPolicy(policy: .allowAll, isFailure: false)
                default:
                    // 5xx and other errors: disallow all
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
            return result.policy.isAllowed(path: pathAndQuery(from: url))
        } catch {
            // Cache failure for 10 minutes
            let failurePolicy = CachedPolicy(policy: .disallowAll, isFailure: true)
            let expiresAt = now().addingTimeInterval(failureTTL)
            cache[cacheKey] = CacheEntry(policy: failurePolicy, expiresAt: expiresAt)
            inFlight[cacheKey] = nil
            return false
        }
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