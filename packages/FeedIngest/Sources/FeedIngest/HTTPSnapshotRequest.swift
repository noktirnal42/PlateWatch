import Foundation

/// A parsed HTTP/1.1 request (just what the Hub's snapshot endpoint needs).
public struct HTTPRequest: Sendable, Equatable {
    public var method: String
    public var path: String
    /// Header names are lower-cased.
    public var headers: [String: String]
    /// Raw bytes — never decoded as text (images are binary).
    public var body: Data
}

/// Accumulates socket reads until one complete HTTP request has arrived.
///
/// The Hub used to take a single 64 KB read and decode it as UTF-8, which truncated every
/// real camera snapshot and corrupted the JPEG bytes. This buffers by `Content-Length`
/// instead, with hard limits so a misbehaving client cannot exhaust memory.
public struct HTTPRequestBuffer: Sendable {
    public enum State: Sendable, Equatable {
        case needMore
        case complete(HTTPRequest)
        case reject(status: Int, reason: String)
    }

    public static let maxHeaderBytes = 16 * 1024
    public static let maxBodyBytes = 25 * 1024 * 1024

    private var data = Data()
    private var parsedHead: (request: HTTPRequest, bodyStart: Int, length: Int)?
    private var sentContinue = false

    public init() {}

    /// True once, when a client sent `Expect: 100-continue` and is waiting for permission to
    /// send the body (curl does this for uploads over 1 MB). The caller replies with
    /// `HTTPResponses.continue100`.
    public mutating func takeContinueRequest() -> Bool {
        guard let head = parsedHead, !sentContinue,
              head.request.headers["expect"]?.lowercased() == "100-continue",
              data.count < head.bodyStart + head.length else { return false }
        sentContinue = true
        return true
    }

    public mutating func append(_ chunk: Data) -> State {
        data.append(chunk)
        if parsedHead == nil {
            let terminator = Data("\r\n\r\n".utf8)
            guard let end = data.range(of: terminator) else {
                return data.count > Self.maxHeaderBytes
                    ? .reject(status: 431, reason: "Headers too large") : .needMore
            }
            guard end.lowerBound <= Self.maxHeaderBytes else {
                return .reject(status: 431, reason: "Headers too large")
            }
            // Headers are ASCII; the body is never touched as text.
            let head = String(decoding: data[data.startIndex..<end.lowerBound], as: UTF8.self)
            var lines = head.components(separatedBy: "\r\n")
            let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
            guard requestLine.count >= 2 else { return .reject(status: 400, reason: "Bad request line") }
            var headers: [String: String] = [:]
            for line in lines {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] =
                    line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let method = String(requestLine[0]).uppercased()
            var length = 0
            if method == "POST" || method == "PUT" {
                guard let raw = headers["content-length"] else {
                    return .reject(status: 411, reason: "Content-Length required")
                }
                guard let parsed = Int(raw), parsed >= 0 else { return .reject(status: 400, reason: "Bad Content-Length") }
                guard parsed <= Self.maxBodyBytes else { return .reject(status: 413, reason: "Body too large") }
                length = parsed
            }
            parsedHead = (HTTPRequest(method: method, path: String(requestLine[1]), headers: headers, body: Data()),
                          end.upperBound - data.startIndex, length)
        }
        guard let head = parsedHead else { return .needMore }
        guard data.count - head.bodyStart >= head.length else { return .needMore }
        var request = head.request
        request.body = data.subdata(in: (data.startIndex + head.bodyStart)..<(data.startIndex + head.bodyStart + head.length))
        return .complete(request)
    }
}

public enum HTTPResponses {
    public static let continue100 = Data("HTTP/1.1 100 Continue\r\n\r\n".utf8)

    /// A complete plain-text response with correct CRLF framing.
    public static func text(status: Int, _ body: String) -> Data {
        let reason = HTTPURLResponse.localizedString(forStatusCode: status).capitalized
        var out = Data("HTTP/1.1 \(status) \(reason)\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(Data(body.utf8))
        return out
    }
}
