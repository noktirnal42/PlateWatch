import Foundation

public struct PublicPassage: Codable, Sendable, Identifiable, Equatable {
    public let id: UUID
    public let text: String
    public let sourceURL: URL
    public let page: Int
    public init(id: UUID = UUID(), text: String, sourceURL: URL, page: Int) throws {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 8000,
              sourceURL.scheme == "https", sourceURL.host != nil, sourceURL.user == nil, sourceURL.password == nil,
              page > 0, page <= 100_000 else { throw NIMError.invalidInput }
        self.id = id; self.text = text; self.sourceURL = sourceURL; self.page = page
    }
}
public struct RankedPassage: Sendable, Identifiable {
    public var id: UUID { passage.id }
    public let passage: PublicPassage
    public let score: Double
}
public struct ExtractedElement: Codable, Sendable {
    public struct Box: Codable, Sendable { public let xmin: Double, ymin: Double, xmax: Double, ymax: Double }
    public let text: String
    public let type: String
    public let bbox: Box
}
public struct ExtractedPage: Codable, Sendable {
    public let text: String
    public let sourceURL: URL
    public let page: Int
    public let model: String
    public let elements: [ExtractedElement]
}

extension NIMClient {
    public func embeddings(_ texts: [String], query: Bool) async throws -> [[Double]] {
        guard !texts.isEmpty, texts.count <= 32, texts.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 8000 }) else { throw NIMError.invalidInput }
        let body = try Self.encode(["model": Self.embeddingModel, "input": texts, "input_type": query ? "query" : "passage", "encoding_format": "float", "truncate": "NONE"])
        struct Response: Decodable { struct Item: Decodable { let index: Int; let embedding: [Double] }; let data: [Item] }
        let data = try await post(.embedding, body: body)
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.data.count == texts.count,
              Set(response.data.map(\.index)) == Set(texts.indices), let dimension = response.data.first?.embedding.count,
              dimension > 0, dimension <= 8192, response.data.allSatisfy({ $0.embedding.count == dimension && $0.embedding.allSatisfy(\.isFinite) }) else { throw NIMError.invalidResponse }
        return response.data.sorted { $0.index < $1.index }.map(\.embedding)
    }
    public func search(query: String, passages: [PublicPassage]) async throws -> [RankedPassage] {
        guard !query.isEmpty, query.utf8.count <= 1000, !passages.isEmpty, passages.count <= 24 else { throw NIMError.invalidInput }
        for passage in passages { _ = try PublicPassage(id: passage.id, text: passage.text, sourceURL: passage.sourceURL, page: passage.page) }
        let vectors = try await embeddings(passages.map(\.text), query: false)
        let queryVectors = try await embeddings([query], query: true)
        guard let q = queryVectors.first, vectors.allSatisfy({ $0.count == q.count }) else { throw NIMError.invalidResponse }
        // Retrieve with cosine similarity, then use the distinct ranking model.
        let candidates = passages.indices.sorted { Self.cosine(q, vectors[$0]) > Self.cosine(q, vectors[$1]) }.prefix(10).map { passages[$0] }
        let body = try Self.encode(["model": Self.rerankModel, "query": ["text": query], "passages": candidates.map { ["text": $0.text] }, "truncate": "NONE"])
        struct Response: Decodable { struct Rank: Decodable { let index: Int; let logit: Double }; let rankings: [Rank] }
        let data = try await post(.rerank, body: body)
        guard let response = try? JSONDecoder().decode(Response.self, from: data), !response.rankings.isEmpty,
              Set(response.rankings.map(\.index)).count == response.rankings.count,
              response.rankings.allSatisfy({ candidates.indices.contains($0.index) && $0.logit.isFinite }) else { throw NIMError.invalidResponse }
        return response.rankings.sorted { $0.logit > $1.logit }.map { .init(passage: candidates[$0.index], score: $0.logit) }
    }
    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        let divisor = sqrt(a.reduce(0) { $0 + $1 * $1 } * b.reduce(0) { $0 + $1 * $1 })
        return divisor > 0 ? zip(a,b).reduce(0) { $0 + $1.0 * $1.1 } / divisor : 0
    }
    public func extractPublicPage(jpeg: Data, citation: PublicPassage) async throws -> ExtractedPage {
        guard !jpeg.isEmpty, jpeg.count <= 175_000, jpeg.prefix(2) == Data([0xff,0xd8]) else { throw NIMError.invalidInput }
        let body = try Self.encode(["model": "nvidia/nemotron-parse", "stream": false, "max_tokens": 4096,
            "messages": [["role": "user", "content": [["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]]]]])
        let data = try await post(.chat, body: body)
        return try Self.extractedPage(data, citation: citation)
    }
    public static func extractedPage(_ data: Data, citation: PublicPassage) throws -> ExtractedPage {
        struct Response: Decodable {
            struct Choice: Decodable {
                struct Message: Decodable {
                    struct Tool: Decodable { struct Function: Decodable { let name: String; let arguments: String }; let function: Function }
                    let content: String?
                    let tool_calls: [Tool]?
                }
                let message: Message
                let finish_reason: String?
            }
            let choices: [Choice]
        }
        guard data.count <= 1_000_000, let response = try? JSONDecoder().decode(Response.self, from: data),
              response.choices.count == 1, let choice = response.choices.first, choice.finish_reason != "length" else { throw NIMError.invalidResponse }
        var elements: [ExtractedElement] = []
        // Parse returns document regions in a function-shaped envelope. They are DATA, never executed tools.
        for tool in choice.message.tool_calls ?? [] {
            guard tool.function.name == "markdown_bbox", tool.function.arguments.utf8.count <= 200_000,
                  let pages = try? JSONDecoder().decode([[ExtractedElement]].self, from: Data(tool.function.arguments.utf8)), pages.count == 1 else { throw NIMError.invalidResponse }
            elements += pages.flatMap { $0 }
        }
        guard elements.count <= 200, elements.allSatisfy({ element in
            let b = element.bbox
            return element.text.utf8.count <= 20_000 && element.type.utf8.count <= 100 && [b.xmin,b.ymin,b.xmax,b.ymax].allSatisfy { $0.isFinite && (0...1).contains($0) } && b.xmax > b.xmin && b.ymax > b.ymin
        }) else { throw NIMError.invalidResponse }
        let text = elements.isEmpty ? choice.message.content ?? "" : elements.map(\.text).joined(separator: "\n\n")
        guard !text.isEmpty, text.utf8.count <= 200_000 else { throw NIMError.invalidResponse }
        return .init(text: text, sourceURL: citation.sourceURL, page: citation.page, model: "nvidia/nemotron-parse", elements: elements)
    }
    /// Returns the provider's bounded detection JSON for a separate labeled benchmark.
    /// It never alters the production recognition pipeline or queues fleet sightings.
    public func detectPublicFixture(jpeg: Data) async throws -> Data {
        guard !jpeg.isEmpty, jpeg.count <= 175_000, jpeg.prefix(2) == Data([0xff,0xd8]) else { throw NIMError.invalidInput }
        let body = try Self.encode(["model": Self.visionModel, "stream": false, "max_tokens": 2048,
            "temperature": 0.6, "top_p": 0.95, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "user", "content": [
                ["type": "text", "text": "Return only JSON: {\"detections\":[{\"label\":\"car\",\"box\":{\"x\":0.1,\"y\":0.2,\"width\":0.3,\"height\":0.4}}]}. Locate up to 32 visible road vehicles (car, SUV, truck, bus, motorcycle). Coordinates must be normalized 0..1 from TOP LEFT; width and height are sizes, not endpoints. Exclude objects that are not vehicles. Do not read plates or identify people. No prose, markdown, or confidence claims. Empty detections is valid."],
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64,\(jpeg.base64EncodedString())"]]
            ]]]])
        let response = try await post(.chat, body: body)
        // Decode/validate before exposing results; a VLM box is an uncalibrated hypothesis.
        let detections = try VehicleResearchBenchmark.decodeVLM(response)
        return try JSONEncoder().encode(detections)
    }
}
