import Foundation
import Network

/// Keeps AVPlayer on a private loopback resource graph. Every upstream request,
/// including redirects, must pass the caller's reviewed-host and robots policy.
/// Only URLs declared by fetched playlists acquire local capability routes.
@MainActor
public final class HLSPolicyRelay {
    public typealias Policy = @Sendable (URL) async -> Bool
    private let root: URL
    private let fetcher: HLSResourceFetcher
    private var listener: NWListener?
    private var origin: URL?
    private let capability = UUID().uuidString
    private var routes: [String: URL] = [:]
    private var reverse: [URL: String] = [:]
    private var routeOrder: [String] = []
    private var connections: [UUID: NWConnection] = [:]
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var streaming: Set<UUID> = []
    private var chunked: Set<UUID> = []
    private var stopped = false
    public private(set) var lastFailure: String?

    public init(url: URL, policy: @escaping Policy, configuration: URLSessionConfiguration = .ephemeral) {
        root = url
        fetcher = HLSResourceFetcher(policy: policy, configuration: configuration)
    }

    public func start() async throws -> URL {
        guard listener == nil, !stopped else { throw URLError(.cancelled) }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let once = HLSRelayStart(continuation)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(nil)
                case .failed(let error): once.finish(error)
                case .cancelled: once.finish(URLError(.cancelled))
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.accept(connection) }
            }
            listener.start(queue: .global(qos: .utility))
        }
        guard !stopped, let port = listener.port else { throw URLError(.cancelled) }
        origin = URL(string: "http://127.0.0.1:\(port.rawValue)")!
        return try route(root)
    }

    public func stop() {
        stopped = true
        listener?.cancel(); listener = nil
        tasks.values.forEach { $0.cancel() }; tasks.removeAll()
        connections.values.forEach { $0.cancel() }; connections.removeAll()
        fetcher.stop()
        routes.removeAll(); reverse.removeAll(); routeOrder.removeAll()
    }

    private func route(_ remote: URL) throws -> URL {
        guard let origin, Self.supported(remote) else { throw URLError(.unsupportedURL) }
        if let key = reverse[remote] { return origin.appendingPathComponent("\(capability)/\(key)") }
        let key = UUID().uuidString + (remote.pathExtension.isEmpty ? "" : "." + remote.pathExtension)
        routes[key] = remote; reverse[remote] = key; routeOrder.append(key)
        // Live playlists refresh forever; do not keep an unbounded segment map.
        while routeOrder.count > 2048 {
            let old = routeOrder.removeFirst()
            if let url = routes[old], url != root { reverse[url] = nil; routes[old] = nil }
        }
        return origin.appendingPathComponent("\(capability)/\(key)")
    }

    nonisolated static func supported(_ url: URL) -> Bool {
        guard url.user == nil, url.password == nil, url.host != nil else { return false }
        return url.scheme == "https" || (url.scheme == "http" && url.host == "127.0.0.1")
    }

    /// Rewrites segment lines and quoted URI attributes (keys, maps, renditions,
    /// parts). Unsupported variable/steering playlists fail closed rather than
    /// handing AVPlayer an unmediated alternate network path.
    nonisolated static func rewrite(_ text: String, base: URL, route: (URL) throws -> URL) throws -> String {
        guard text.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U"),
              !text.contains("#EXT-X-DEFINE:"), !text.contains("#EXT-X-CONTENT-STEERING:") else {
            throw URLError(.cannotParseResponse)
        }
        let regex = try NSRegularExpression(pattern: #"(?:^|[:,])\s*(?:[A-Z0-9-]*URI)="([^"]*)""#)
        let attributes = try NSRegularExpression(pattern: #"(?:^|[:,])\s*(?:[A-Z0-9-]*URI)="#)
        func resolved(_ value: String) throws -> URL {
            guard !value.contains("{$"), let url = URL(string: value, relativeTo: base)?.absoluteURL,
                  supported(url) else { throw URLError(.unsupportedURL) }
            return try route(url)
        }
        return try text.components(separatedBy: "\n").map { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return line }
            if !trimmed.hasPrefix("#") { return try resolved(trimmed).absoluteString }
            let range = NSRange(line.startIndex..., in: line)
            let matches = regex.matches(in: line, range: range)
            guard matches.count == attributes.numberOfMatches(in: line, range: range) else { throw URLError(.cannotParseResponse) }
            var result = line
            for match in matches.reversed() {
                guard let range = Range(match.range(at: 1), in: result) else { throw URLError(.cannotParseResponse) }
                result.replaceSubrange(range, with: try resolved(String(result[range])).absoluteString)
            }
            return result
        }.joined(separator: "\n")
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, connections.count < 8 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .global(qos: .utility))
        receive(connection, id: id, data: Data())
        tasks[id] = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .seconds(25)) } catch { return }
            self?.finish(connection, id: id)
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] chunk, _, complete, error in
            Task { @MainActor in
                guard let self, !self.stopped, self.connections[id] != nil else { return }
                var data = data; if let chunk { data.append(chunk) }
                guard error == nil, data.count <= 32768 else { self.finish(connection, id: id); return }
                if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                    self.tasks[id]?.cancel()
                    self.tasks[id] = Task { @MainActor [weak self] in await self?.respond(connection, id: id, header: data) }
                } else if complete { self.finish(connection, id: id) }
                else { self.receive(connection, id: id, data: data) }
            }
        }
    }

    private func respond(_ connection: NWConnection, id: UUID, header: Data) async {
        let lines = String(decoding: header, as: UTF8.self).components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        guard parts.count == 3, parts[0] == "GET" || parts[0] == "HEAD" else {
            send(connection, id: id, code: 405, type: "text/plain", data: Data()); return
        }
        let path = String(parts[1]).split(separator: "/")
        guard path.count == 2, String(path[0]) == capability, let remote = routes[String(path[1])],
              !lines.contains(where: { $0.lowercased().hasPrefix("origin:") }) else {
            send(connection, id: id, code: 403, type: "text/plain", data: Data()); return
        }
        let range = lines.first { $0.lowercased().hasPrefix("range:") }?.dropFirst(6).trimmingCharacters(in: .whitespaces)
        do {
            let result = try await fetcher.load(remote, range: range, header: { [weak self] response in
                guard let self else { throw CancellationError() }
                try await self.beginStream(connection, id: id, response: response)
            }, chunk: { [weak self] data in
                guard let self else { throw CancellationError() }
                try await self.streamChunk(connection, id: id, data: data)
            })
            try Task.checkCancellation()
            guard let result else {
                if chunked.contains(id) { try await write(connection, id: id, data: Data("0\r\n\r\n".utf8)) }
                finish(connection, id: id)
                return
            }
            var data = result.data
            var type = result.response.mimeType ?? "application/octet-stream"
            if remote.pathExtension.lowercased() == "m3u8" || data.starts(with: Data("#EXTM3U".utf8)) {
                guard data.count <= 1_048_576, let text = String(data: data, encoding: .utf8) else { throw URLError(.cannotParseResponse) }
                let rewritten = try Self.rewrite(text, base: result.response.url ?? remote) { try self.route($0) }
                data = Data(rewritten.utf8); type = "application/vnd.apple.mpegurl"
            }
            guard !stopped else { return }
            send(connection, id: id, code: result.response.statusCode, type: type, data: data,
                 contentRange: result.response.value(forHTTPHeaderField: "Content-Range"), head: parts[0] == "HEAD")
        } catch {
            guard !stopped else { return }
            // No remote URL, query, credential or image bytes in the diagnostic.
            lastFailure = "Stream resource unavailable (\((error as NSError).domain) \((error as NSError).code))."
            if streaming.contains(id) { finish(connection, id: id) }
            else { send(connection, id: id, code: 502, type: "text/plain", data: Data()) }
        }
    }

    private func beginStream(_ connection: NWConnection, id: UUID, response: HTTPURLResponse) async throws {
        guard !stopped, connections[id] != nil else { throw CancellationError() }
        streaming.insert(id)
        var header = "HTTP/1.1 \(response.statusCode) Response\r\nConnection: close\r\nCache-Control: no-store\r\n"
        let type = response.mimeType ?? "application/octet-stream"
        if type.range(of: #"^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$"#, options: .regularExpression) != nil { header += "Content-Type: \(type)\r\n" }
        if response.expectedContentLength >= 0 { header += "Content-Length: \(response.expectedContentLength)\r\n" }
        else { chunked.insert(id); header += "Transfer-Encoding: chunked\r\n" }
        if let range = response.value(forHTTPHeaderField: "Content-Range"), !range.contains("\r"), !range.contains("\n") {
            header += "Content-Range: \(range)\r\nAccept-Ranges: bytes\r\n"
        }
        try await write(connection, id: id, data: Data((header + "\r\n").utf8))
    }

    private func streamChunk(_ connection: NWConnection, id: UUID, data: Data) async throws {
        var body = Data()
        if chunked.contains(id) { body.append(Data("\(String(data.count, radix: 16))\r\n".utf8)) }
        body.append(data)
        if chunked.contains(id) { body.append(Data("\r\n".utf8)) }
        try await write(connection, id: id, data: body)
    }

    private func write(_ connection: NWConnection, id: UUID, data: Data) async throws {
        guard !stopped, connections[id] != nil, !Task.isCancelled else { throw CancellationError() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }

    private func send(_ connection: NWConnection, id: UUID, code: Int, type: String, data: Data, contentRange: String? = nil, head: Bool = false) {
        let type = type.range(of: #"^[A-Za-z0-9.+-]+/[A-Za-z0-9.+-]+$"#, options: .regularExpression) != nil ? type : "application/octet-stream"
        var header = "HTTP/1.1 \(code) Response\r\nContent-Type: \(type)\r\nContent-Length: \(data.count)\r\nConnection: close\r\nCache-Control: no-store\r\n"
        if let contentRange, !contentRange.contains("\r"), !contentRange.contains("\n") { header += "Content-Range: \(contentRange)\r\nAccept-Ranges: bytes\r\n" }
        var response = Data((header + "\r\n").utf8)
        if !head { response.append(data) }
        connection.send(content: response, completion: .contentProcessed { [weak self] _ in
            Task { @MainActor in self?.finish(connection, id: id) }
        })
    }
    private func finish(_ connection: NWConnection, id: UUID) {
        tasks.removeValue(forKey: id)?.cancel()
        streaming.remove(id); chunked.remove(id)
        connections[id] = nil; connection.cancel()
    }
}

private final class HLSRelayStart: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    init(_ continuation: CheckedContinuation<Void, Error>) { self.continuation = continuation }
    func finish(_ error: Error?) {
        let value = lock.withLock { let value = continuation; continuation = nil; return value }
        if let error { value?.resume(throwing: error) } else { value?.resume() }
    }
}

final class HLSRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let policy: HLSPolicyRelay.Policy
    init(_ policy: @escaping HLSPolicyRelay.Policy) { self.policy = policy }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        Task {
            guard let url = request.url, HLSPolicyRelay.supported(url), await policy(url), !Task.isCancelled else { completionHandler(nil); return }
            completionHandler(request)
        }
    }
}

private actor HLSResourceFetcher {
    struct Result: @unchecked Sendable { let data: Data; let response: HTTPURLResponse }
    nonisolated let session: URLSession
    let policy: HLSPolicyRelay.Policy
    init(policy: @escaping HLSPolicyRelay.Policy, configuration: URLSessionConfiguration) {
        self.policy = policy
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "PlateWatchHub/0.1 (+https://github.com/noktirnal42/PlateWatch)"]
        session = URLSession(configuration: configuration, delegate: HLSRedirectPolicy(policy), delegateQueue: nil)
    }
    nonisolated func stop() {
        // URLSession.invalidateAndCancel() can abort AsyncBytes with an
        // Objective-C exception while a relay task is being torn down. Cancel
        // active tasks individually; the request timeout still bounds any
        // task that does not observe cancellation immediately.
        session.getAllTasks { tasks in tasks.forEach { $0.cancel() } }
    }
    func load(_ url: URL, range: String?,
              header: @Sendable (HTTPURLResponse) async throws -> Void,
              chunk: @Sendable (Data) async throws -> Void) async throws -> Result? {
        guard HLSPolicyRelay.supported(url), await policy(url) else { throw URLError(.noPermissionsToReadFile) }
        var request = URLRequest(url: url)
        if let range {
            guard range.range(of: #"^bytes=[0-9]+-[0-9]*$"#, options: .regularExpression) != nil else { throw URLError(.badURL) }
            request.setValue(range, forHTTPHeaderField: "Range")
        }
        // Foundation's AsyncBytes bridge can throw an Objective-C exception when
        // a URLSession is cancelled while a relay connection is being torn down.
        // Use the bounded data API instead. The relay still enforces the same
        // response and byte limits, and sends the validated body only after the
        // policy-checked request completes.
        try Task.checkCancellation()
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse, response.statusCode == 200 || response.statusCode == 206,
              response.expectedContentLength <= 8_388_608 else { throw URLError(.badServerResponse) }
        let playlist = url.pathExtension.lowercased() == "m3u8" || (response.mimeType?.lowercased().contains("mpegurl") == true)
        if !playlist { try await header(response) }
        let limit = playlist ? 1_048_576 : 8_388_608
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        if playlist { return .init(data: data, response: response) }
        if !data.isEmpty { try await chunk(data) }
        return nil
    }
}
