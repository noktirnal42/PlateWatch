import Foundation

public enum NIMError: Error, LocalizedError, Sendable {
    case missingKey, invalidInput, invalidResponse, oversized, http(Int)
    public var errorDescription: String? {
        switch self {
        case .missingKey: "Add your NVIDIA API key in Settings."
        case .invalidInput: "Supply bounded public content and an HTTPS source citation."
        case .invalidResponse: "NVIDIA returned an unsupported response. No records were changed."
        case .oversized: "The request or response exceeds the hosted research limit."
        case .http(let code): code == 202 ? "NVIDIA is still processing the request; do not resubmit automatically." : code == 429 ? "NVIDIA rate limit reached. Wait before retrying." : "NVIDIA returned HTTP \(code). Check account access and quota."
        }
    }
}

public enum NIMEndpoint: String, Sendable {
    case chat = "https://integrate.api.nvidia.com/v1/chat/completions"
    case embedding = "https://integrate.api.nvidia.com/v1/embeddings"
    case rerank = "https://ai.api.nvidia.com/v1/retrieval/nvidia/llama-nemotron-rerank-vl-1b-v2/reranking"
}

public struct NIMResponse: Sendable {
    public let data: Data
    public let status: Int
    public let requestID: String?
    public init(data: Data = Data(), status: Int = 200, requestID: String? = nil) { self.data = data; self.status = status; self.requestID = requestID }
}
public protocol NIMTransport: Sendable {
    func send(_ request: URLRequest) async throws -> NIMResponse
}

private final class NoRedirect: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

public struct HostedNIMTransport: NIMTransport {
    public init() {}
    public func send(_ request: URLRequest) async throws -> NIMResponse {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 45
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: NoRedirect(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse else { throw NIMError.invalidResponse }
        guard response.statusCode == 200 else { return NIMResponse(status: response.statusCode, requestID: response.value(forHTTPHeaderField: "NVCF-REQID")) }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 1_000_000 else { throw NIMError.oversized }
            data.append(byte)
        }
        return NIMResponse(data: data, status: response.statusCode)
    }
}

public struct NIMClient: Sendable {
    public static let visionModel = "nvidia/nemotron-3.5-super-vl-120b-a12b"
    public static let agentModel = "nvidia/nemotron-3-super-120b-a12b"
    public static let embeddingModel = "nvidia/nemotron-3-embed-1b"
    public static let rerankModel = "nvidia/llama-nemotron-rerank-vl-1b-v2"
    private let transport: any NIMTransport
    private let credential: @Sendable () async -> String?
    public init(transport: any NIMTransport = HostedNIMTransport(), credential: @escaping @Sendable () async -> String?) {
        self.transport = transport; self.credential = credential
    }
    func post(_ endpoint: NIMEndpoint, body: Data) async throws -> Data {
        try Task.checkCancellation()
        guard body.count <= 300_000 else { throw NIMError.oversized }
        guard let key = await credential(), !key.isEmpty, key.utf8.count <= 4096,
              !key.contains("\n"), !key.contains("\r") else { throw NIMError.missingKey }
        var request = URLRequest(url: URL(string: endpoint.rawValue)!)
        request.httpMethod = "POST"; request.timeoutInterval = 45; request.httpBody = body
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // No automatic retry: an uncertain paid request may already have been processed.
        var response = try await transport.send(request)
        if response.status == 202 {
            guard let requestID = response.requestID, let uuid = UUID(uuidString: requestID), let host = request.url?.host else { throw NIMError.invalidResponse }
            // Poll only the original documented NVIDIA origin and a validated UUID, never a returned URL.
            var poll = URLRequest(url: URL(string: "https://" + host + "/v1/status/" + uuid.uuidString)!)
            poll.timeoutInterval = 5
            poll.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
            poll.setValue("application/json", forHTTPHeaderField: "Accept")
            for _ in 0..<10 {
                try await Task.sleep(for: .seconds(1))
                response = try await transport.send(poll)
                if response.status != 202 { break }
            }
        }
        try Task.checkCancellation()
        guard response.status == 200 else { throw NIMError.http(response.status) }
        guard response.data.count <= 1_000_000 else { throw NIMError.oversized }
        return response.data
    }
    static func encode(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
    static func chatText(_ data: Data) throws -> String {
        struct Response: Decodable { struct Choice: Decodable { struct Message: Decodable { let content: String? }; let message: Message; let finish_reason: String? }; let choices: [Choice] }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), let first = response.choices.first,
              first.finish_reason != "length", let text = first.message.content, !text.isEmpty else { throw NIMError.invalidResponse }
        return text
    }
}
