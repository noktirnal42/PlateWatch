import Foundation
import PlateKit
import XCTest
@testable import PlateSync

final class RESTPrivacyTests: XCTestCase {
    func testActualRESTRequestOmitsPrivateFields() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [PrivacyProbeProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let backend = RESTBackend(baseURL: URL(string: "https://local.privacy.test")!, session: session)
        let local = SightingSubmissionDTO(capturedAt: Date(), geohash6: "9q8yyk",
            exactLatitude: 37, exactLongitude: -122, cropHashSHA256: "fixture-hash",
            cropJPEGBase64: "local-image-bytes", deviceIDHash: "fixture", fleetConfidence: 0.5,
            plate: .init(text: "PRIVATE-FIXTURE"), vehicle: .init(vehicleClass: "unknown", classConfidence: 0.5))
        let receipt = try await backend.submit(local, idempotencyKey: "privacy-fixture")
        XCTAssertEqual(receipt.sightingID.uuidString, "00000000-0000-0000-0000-000000000001")
    }

    func testLocalThumbnailNeverLeavesDeviceEvenForFleetConfirmedSubmission() throws {
        let local = SightingSubmissionDTO(capturedAt: Date(), geohash6: "9q8yyk",
            exactLatitude: 37, exactLongitude: -122, cropHashSHA256: "fixture-hash",
            cropJPEGBase64: "local-image-bytes", deviceIDHash: "fixture", fleetConfidence: 0.95,
            plate: .init(text: "FLEET-FIXTURE"), vehicle: .init(vehicleClass: "patrol", classConfidence: 0.95),
            markings: .init(agencyText: "SYNTHETIC CITY", unitNumber: "QA"))
        let wire = RESTBackend.networkPayload(local)
        let encoded = try JSONEncoder().encode(wire)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(json["cropJPEGBase64"])
        XCTAssertEqual(wire.cropHashSHA256, "fixture-hash")
        XCTAssertEqual(wire.plate?.text, "FLEET-FIXTURE")
        XCTAssertEqual(wire.exactLatitude, 37)
        XCTAssertEqual(local.cropJPEGBase64, "local-image-bytes", "Local evidence is preserved")
    }

    func testUnconfirmedSubmissionStripsRegistrationAndExactLocation() {
        for (confidence, markings) in [(0.6, FleetMarkingsDTO(agencyText: "SYNTHETIC CITY")), (0.95, nil)] {
            let local = SightingSubmissionDTO(capturedAt: Date(), geohash6: "9q8yyk",
                exactLatitude: 37, exactLongitude: -122, deviceIDHash: "fixture", fleetConfidence: confidence,
                plate: .init(text: "PRIVATE-FIXTURE"), vehicle: .init(vehicleClass: "unknown", classConfidence: 0.5),
                markings: markings, identity: .init(plate: .init(registration: "PRIVATE-FIXTURE", state: "CA", confidence: 0.9)))
            let wire = RESTBackend.networkPayload(local)
            XCTAssertNil(wire.plate)
            XCTAssertEqual(wire.identity?.plate?.registration, "")
            XCTAssertNil(wire.exactLatitude)
            XCTAssertNil(wire.exactLongitude)
            XCTAssertEqual(wire.geohash6, "9q8yyk")
        }
    }
}

/// A request carrying forbidden bytes receives HTTP 422. No network or live database is used.
private final class PrivacyProbeProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while true {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let safe = json != nil && json?["cropJPEGBase64"] == nil && json?["plate"] == nil
            && json?["exactLatitude"] == nil && json?["exactLongitude"] == nil
            && json?["cropHashSHA256"] as? String == "fixture-hash"
            && request.value(forHTTPHeaderField: "Idempotency-Key") == "privacy-fixture"
        let response = HTTPURLResponse(url: request.url!, statusCode: safe ? 200 : 422,
                                       httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        let body = Data(#"{"sightingID":"00000000-0000-0000-0000-000000000001","moderationState":"pending","serverReceivedAt":"2026-10-15T12:00:00Z"}"#.utf8)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}
