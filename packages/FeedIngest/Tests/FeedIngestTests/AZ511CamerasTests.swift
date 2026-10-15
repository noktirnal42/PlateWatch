import Foundation
import XCTest

@testable import FeedIngest

/// The AZ511 importer parses the documented IBI 511 v2 camera schema. The live
/// response needs a keyed verification pass; these fixtures pin the parser
/// against the published shape (and its case variants) without network access.
final class AZ511CamerasTests: XCTestCase {
    private let endpoint = URL(string: "https://ibi.az511.gov/api/v2/get/cameras")!

    private func fixture(_ json: String) throws -> SocrataImportResult {
        try AZ511Cameras.sources(fromJSON: Data(json.utf8), key: "test-key", endpointURL: endpoint)
    }

    func testMissingKeyIsRefusedWithoutNetwork() {
        XCTAssertThrowsError(try AZ511Cameras.sources(fromJSON: Data("[]".utf8), key: "  ")) { error in
            XCTAssertEqual(error as? AZ511Cameras.ImportError, .missingKey)
        }
    }

    func testParsesDocumentedSchemaAndStampsArizona() throws {
        let json = """
        [
          {"Id": "AZ-1", "Name": "SR 51 @ Shea Blvd", "Url": "https://images.az511.gov/cam/az1.jpg",
           "Latitude": 33.5842, "Longitude": -111.9771},
          {"id": "AZ-2", "name": "I-10 @ Broadway", "url": "https://images.az511.gov/cam/az2.jpg",
           "latitude": "32.2214", "longitude": "-110.9698"}
        ]
        """
        let result = try fixture(json)
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertEqual(result.sources.map(\.state), ["AZ", "AZ"])
        XCTAssertTrue(result.sources.allSatisfy { $0.kind == .snapshotJPEG })
        XCTAssertEqual(result.sources[0].name, "SR 51 @ Shea Blvd")
        // Stable ids: the same camera keeps its id across re-imports.
        XCTAssertEqual(result.sources[0].id, AZ511Cameras.stableUUID(endpoint, "AZ-1"))
        XCTAssertTrue(result.sources[0].terms.automatedUseAllowed == false, "imports are never pre-confirmed")
        XCTAssertEqual(result.sources[0].terms.attribution, "Arizona 511 / ADOT")
    }

    func testWrapperShapesAndSkipReasons() throws {
        let json = """
        {"items": [
          {"Id": "OK-1", "Name": "Loop 101 @ Ray", "Url": "https://images.az511.gov/cam/ok1.jpg",
           "Latitude": 33.3, "Longitude": -111.9},
          {"Id": "NO-IMG", "Name": "No image", "Latitude": 33.0, "Longitude": -111.0},
          {"Id": "HTTP-ONLY", "Name": "Insecure", "Url": "http://images.az511.gov/cam/x.jpg",
           "Latitude": 33.0, "Longitude": -111.0},
          {"Id": "BAD-GEO", "Name": "No coords", "Url": "https://images.az511.gov/cam/y.jpg"},
          {"Id": "DUP", "Name": "First", "Url": "https://images.az511.gov/cam/d.jpg",
           "Latitude": 33.1, "Longitude": -111.1}
        ]}
        """
        // A second DUP with the same id must be de-duplicated.
        let extra = """
          ,{"Id": "DUP", "Name": "Second", "Url": "https://images.az511.gov/cam/d2.jpg",
           "Latitude": 33.1, "Longitude": -111.1}
        """
        let withDup = json.replacingOccurrences(of: "]}", with: extra + "]}")
        let result = try fixture(withDup)
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertEqual(result.skippedCount, 3)
        XCTAssertTrue(result.skipReasons.contains { $0.reason == .missingImageURL })
        XCTAssertTrue(result.skipReasons.contains { $0.reason == .nonHTTPSURL })
        XCTAssertTrue(result.skipReasons.contains { $0.reason == .missingCoordinates })
    }

    func testMalformedJSONIsAnError() {
        XCTAssertThrowsError(try fixture("<html>challenge page</html>")) { error in
            XCTAssertEqual(error as? AZ511Cameras.ImportError, .malformed("response is not JSON"))
        }
    }
}
