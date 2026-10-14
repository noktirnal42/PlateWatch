import XCTest
@testable import FeedIngest

final class HTTPSnapshotRequestTests: XCTestCase {

    private func post(_ body: Data, extra: String = "") -> Data {
        var d = Data("POST /snapshot HTTP/1.1\r\nHost: hub.local\r\nContent-Type: image/jpeg\r\nContent-Length: \(body.count)\r\n\(extra)\r\n".utf8)
        d.append(body)
        return d
    }

    /// A body with bytes that are not valid UTF-8 (a JPEG starts FF D8 FF) must arrive intact.
    func testBinaryBodyIsByteExact() {
        let body = Data([0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00, 0x80, 0xFE])
        var buffer = HTTPRequestBuffer()
        guard case .complete(let request) = buffer.append(post(body)) else { return XCTFail("expected complete") }
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.path, "/snapshot")
        XCTAssertEqual(request.body, body)
    }

    /// Bodies larger than one socket read arrive in pieces; the old handler stopped after 64 KB.
    func testBodySplitAcrossManyReads() {
        let body = Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
        let wire = post(body)
        var buffer = HTTPRequestBuffer()
        var result: HTTPRequestBuffer.State = .needMore
        var offset = 0
        while offset < wire.count {
            let end = min(offset + 7_000, wire.count)
            result = buffer.append(wire[offset..<end])
            if offset + 7_000 < wire.count { XCTAssertEqual(result, .needMore) }
            offset = end
        }
        guard case .complete(let request) = result else { return XCTFail("expected complete") }
        XCTAssertEqual(request.body, body)
    }

    func testHeadersSplitMidLine() {
        let wire = post(Data("hello".utf8))
        var buffer = HTTPRequestBuffer()
        XCTAssertEqual(buffer.append(wire.prefix(20)), .needMore)
        guard case .complete(let request) = buffer.append(wire.dropFirst(20)) else { return XCTFail() }
        XCTAssertEqual(request.headers["content-type"], "image/jpeg")
        XCTAssertEqual(String(decoding: request.body, as: UTF8.self), "hello")
    }

    func testRejectsMissingOversizedAndBadLength() {
        var a = HTTPRequestBuffer()
        XCTAssertEqual(a.append(Data("POST /snapshot HTTP/1.1\r\n\r\n".utf8)), .reject(status: 411, reason: "Content-Length required"))
        var b = HTTPRequestBuffer()
        XCTAssertEqual(b.append(Data("POST /snapshot HTTP/1.1\r\nContent-Length: 99999999999\r\n\r\n".utf8)),
                       .reject(status: 413, reason: "Body too large"))
        var c = HTTPRequestBuffer()
        XCTAssertEqual(c.append(Data("POST /snapshot HTTP/1.1\r\nContent-Length: -4\r\n\r\n".utf8)),
                       .reject(status: 400, reason: "Bad Content-Length"))
        var d = HTTPRequestBuffer()
        XCTAssertEqual(d.append(Data(repeating: 0x41, count: HTTPRequestBuffer.maxHeaderBytes + 10)),
                       .reject(status: 431, reason: "Headers too large"))
    }

    func testGetNeedsNoBody() {
        var buffer = HTTPRequestBuffer()
        guard case .complete(let request) = buffer.append(Data("GET /health HTTP/1.1\r\nHost: x\r\n\r\n".utf8)) else { return XCTFail() }
        XCTAssertEqual(request.method, "GET")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testExpectContinueIsAnsweredOnce() {
        var buffer = HTTPRequestBuffer()
        let head = Data("POST /snapshot HTTP/1.1\r\nExpect: 100-continue\r\nContent-Length: 4\r\n\r\n".utf8)
        XCTAssertEqual(buffer.append(head), .needMore)
        XCTAssertTrue(buffer.takeContinueRequest())
        XCTAssertFalse(buffer.takeContinueRequest())
        guard case .complete(let request) = buffer.append(Data("abcd".utf8)) else { return XCTFail() }
        XCTAssertEqual(request.body, Data("abcd".utf8))
    }

    func testResponseUsesCRLFFraming() {
        let text = String(decoding: HTTPResponses.text(status: 200, "OK"), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 200 No Error\r\n") || text.hasPrefix("HTTP/1.1 200 Ok\r\n"), text)
        XCTAssertTrue(text.contains("Content-Length: 2\r\n"))
        XCTAssertTrue(text.hasSuffix("\r\n\r\nOK"))
        XCTAssertFalse(text.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
    }
}
