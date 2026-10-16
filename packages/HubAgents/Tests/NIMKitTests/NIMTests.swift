import Foundation
import HubAgentCore
@testable import NIMKit
import XCTest

private actor Transport: NIMTransport {
    var requests: [URLRequest] = []
    var responses: [NIMResponse]
    init(_ responses: [NIMResponse]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> NIMResponse {
        requests.append(request)
        guard !responses.isEmpty else { throw NIMError.invalidResponse }
        return responses.removeFirst()
    }
}
final class NIMTests: XCTestCase {
    func testMissingCredentialPreventsRequest() async {
        let transport = Transport([])
        let client = NIMClient(transport: transport, credential: { nil })
        do { _ = try await client.embeddings(["public"], query: true); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, NIMError.missingKey.localizedDescription) }
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }
    func testEmbeddingsReorderAndRejectDuplicateIndices() async throws {
        let transport = Transport([.init(data: Data(#"{"data":[{"index":1,"embedding":[0,1]},{"index":0,"embedding":[1,0]}]}"#.utf8)), .init(data: Data(#"{"data":[{"index":0,"embedding":[1]},{"index":0,"embedding":[2]}]}"#.utf8))])
        let client = NIMClient(transport: transport, credential: { "fixture-key" })
        let values = try await client.embeddings(["one", "two"], query: false)
        XCTAssertEqual(values, [[1,0],[0,1]])
        let request = await transport.requests[0]
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
        XCTAssertEqual(body["input_type"] as? String, "passage")
        do { _ = try await client.embeddings(["one", "two"], query: false); XCTFail() } catch { }
    }
    func testSearchPreservesOriginalCitationAndPage() async throws {
        let transport = Transport([
            .init(data: Data(#"{"data":[{"index":0,"embedding":[1,0]},{"index":1,"embedding":[0,1]}]}"#.utf8)),
            .init(data: Data(#"{"data":[{"index":0,"embedding":[1,0]}]}"#.utf8)),
            .init(data: Data(#"{"rankings":[{"index":1,"logit":8},{"index":0,"logit":2}]}"#.utf8))])
        let client = NIMClient(transport: transport, credential: { "fixture-key" })
        let one = try PublicPassage(text: "Fleet budget", sourceURL: URL(string: "https://agency.example/budget")!, page: 2)
        let two = try PublicPassage(text: "Fleet inventory", sourceURL: URL(string: "https://agency.example/inventory")!, page: 9)
        let ranked = try await client.search(query: "Fleet", passages: [one,two])
        XCTAssertEqual(ranked.map(\.passage), [two,one])
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(requests[1].httpBody)) as? [String: Any])
        XCTAssertEqual(body["input_type"] as? String, "query")
    }
    func testAgentRejectsUnsupportedCommandAndPrivateObservations() async throws {
        let transport = Transport([.init(data: Data(#"{"choices":[{"message":{"content":"{\"action\":\"shell\"}"},"finish_reason":"stop"}]}"#.utf8))])
        let model = NIMAgentModel(client: NIMClient(transport: transport, credential: { "fixture-key" }))
        do { _ = try await model.next(task: "Check feeds", observations: [], cancellation: .init()); XCTFail() } catch { }
        do { _ = try await model.next(task: "Read queue", observations: [.init(step: .init(action: .reviewQueue), result: "PRIVATE")], cancellation: .init()); XCTFail() } catch { }
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertFalse(String(decoding: requests[0].httpBody!, as: UTF8.self).contains("PRIVATE"))
    }
    func testHostedContextStripsSecretsAndPrivateHosts() throws {
        let source: [String: Any] = ["items": [
            ["id":"public-id", "name":"Public camera", "host":"camera.agency.example", "terms_confirmed":true, "source":["url":"SECRET"], "favorite":true],
            ["id":"local-id", "host":"192.168.1.2", "terms_confirmed":true],
            ["id":"pending", "host":"camera.example", "terms_confirmed":false]]]
        let sanitized = try NIMPublicContext.sanitize(action: .findFeeds, result: JSONSerialization.data(withJSONObject: source))
        let text = String(decoding: sanitized, as: UTF8.self)
        XCTAssertTrue(text.contains("public-id")); XCTAssertFalse(text.contains("SECRET")); XCTAssertFalse(text.contains("favorite")); XCTAssertFalse(text.contains("local-id")); XCTAssertFalse(text.contains("pending"))
        XCTAssertThrowsError(try NIMPublicContext.sanitize(action: .reviewQueue, result: Data("{}".utf8)))
    }
    func testProviderErrorsDoNotExposeResponseBodyOrKey() async {
        let client = NIMClient(transport: Transport([.init(data: Data("sensitive provider body".utf8), status: 429)]), credential: { "fixture-secret" })
        do { _ = try await client.embeddings(["public"], query: true); XCTFail() }
        catch { XCTAssertFalse(error.localizedDescription.contains("sensitive")); XCTAssertFalse(error.localizedDescription.contains("fixture-secret")) }
    }
    func testDetectionCoordinatesAndDuplicatePredictionsScoreHonestly() throws {
        let data = Data(#"{"choices":[{"message":{"content":{"frameWidth":100,"frameHeight":50,"boundingBoxes":[{"phrase":"car","bboxes":[[10,5,20,10],[10,5,20,10]],"confidence":[0.9,0.8]}]}}}]}"#.utf8)
        let detections = try VehicleResearchBenchmark.decode(data)
        let expected = try ResearchBox.annotations("[[0.1,0.1,0.2,0.2]]")
        let score = try VehicleResearchBenchmark.score(expected: expected, predictions: detections, exhaustive: true)
        XCTAssertEqual(score.matched, 1); XCTAssertEqual(score.unmatchedPredictions, 1); XCTAssertEqual(score.precision, 0.5); XCTAssertEqual(score.recall, 1)
        XCTAssertNil(try VehicleResearchBenchmark.score(expected: expected, predictions: detections, exhaustive: false).precision)
        XCTAssertThrowsError(try ResearchBox.annotations("[[0.9,0.9,0.5,0.5]]"))
    }
    func testAsyncPollingUsesOriginalHostAndUUIDOnly() async throws {
        let id = UUID()
        let transport = Transport([.init(status: 202, requestID: id.uuidString), .init(data: Data(#"{"data":[{"index":0,"embedding":[1]}]}"#.utf8))])
        let client = NIMClient(transport: transport, credential: { "fixture-key" })
        _ = try await client.embeddings(["public"], query: true)
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 2); XCTAssertEqual(requests[1].httpMethod, "GET")
        XCTAssertEqual(requests[1].url?.absoluteString, "https://integrate.api.nvidia.com/v1/status/" + id.uuidString)
    }
    func testParseFunctionEnvelopeRemainsCitedDataAndCannotExecuteTools() throws {
        let citation = try PublicPassage(text: "public fixture", sourceURL: URL(string: "https://agency.example/source")!, page: 4)
        let response: [String:Any] = ["choices":[["finish_reason":"stop","message":["tool_calls":[["function":["name":"markdown_bbox", "arguments":"[[{\"text\":\"Fleet budget\",\"type\":\"Text\",\"bbox\":{\"xmin\":0.1,\"ymin\":0.2,\"xmax\":0.8,\"ymax\":0.4}}]]"]]]]]]]
        let data = try JSONSerialization.data(withJSONObject: response)
        let page = try NIMClient.extractedPage(data, citation: citation)
        XCTAssertEqual(page.text, "Fleet budget"); XCTAssertEqual(page.page, 4); XCTAssertEqual(page.sourceURL, citation.sourceURL); XCTAssertEqual(page.elements.count, 1)
        let injected = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "markdown_bbox", with: "shell")
        XCTAssertThrowsError(try NIMClient.extractedPage(Data(injected.utf8), citation: citation))
    }
    func testVLMBoxesHaveNoInventedConfidence() throws {
        let response: [String:Any] = ["choices":[["finish_reason":"stop","message":["content":"{\"detections\":[{\"label\":\"car\",\"box\":{\"x\":0.1,\"y\":0.1,\"width\":0.2,\"height\":0.2}}]}"]]]]
        let detections = try VehicleResearchBenchmark.decodeVLM(JSONSerialization.data(withJSONObject: response))
        XCTAssertEqual(detections.count, 1); XCTAssertNil(detections[0].confidence)
    }
    func testPublicInputsAndImageBoundsRejectBeforeNetwork() async throws {
        XCTAssertThrowsError(try PublicPassage(text: "text", sourceURL: URL(string: "http://example.com")!, page: 1))
        let transport = Transport([]), client = NIMClient(transport: transport, credential: { "fixture-key" })
        do { _ = try await client.detectPublicFixture(jpeg: Data(repeating: 0xff, count: 180_000)); XCTFail() } catch { }
        let count = await transport.requests.count; XCTAssertEqual(count, 0)
    }
}
