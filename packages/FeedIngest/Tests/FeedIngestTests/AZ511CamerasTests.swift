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

/// Published AZ511 / UDOT sample shape (IBI v2): snapshot URL nested under Views.
final class IBI511SchemaTests: XCTestCase {
    private let az = """
    [{"Id":2056,"Source":"AZDOT","Roadway":"SR-95","Direction":"Unknown","Latitude":35.172449,"Longitude":-114.566108,
      "Location":"SR-95 @SR68 Laughlin Rd","SortOrder":0,
      "Views":[{"Id":960,"Url":"https://az511.com/map/Cctv/960","Status":"Enabled","Description":"SR-95 NB 249.80 @SR68 Laughlin Rd"},
               {"Id":961,"Url":"https://az511.com/map/Cctv/961","Status":"Disabled","Description":"off"}]}]
    """
    func testArizonaNestedViewsImportOnlyEnabledViewsAndNeverConfirm() throws {
        let r = try AZ511Cameras.sources(fromJSON: Data(az.utf8), key: "fixture-key")
        XCTAssertEqual(r.sources.count, 1)
        XCTAssertEqual(r.sources[0].state, "AZ")
        XCTAssertEqual(r.sources[0].url.absoluteString, "https://az511.com/map/Cctv/960")
        XCTAssertFalse(r.sources[0].mayBeAnalysed)
        XCTAssertEqual(r.sources[0].terms.attribution, "Arizona 511 / ADOT")
        XCTAssertFalse(String(decoding: try FeedCatalogue(sources: r.sources).encoded(), as: UTF8.self).contains("fixture-key"))
    }

    func testUtahSampleShape() throws {
        let json = """
        [{"Id":15157,"Source":"ADX","SourceId":"79854","Roadway":"River Rd","Direction":"North","Latitude":37.09616,
          "Longitude":-113.55726,"Location":"River Rd @ 700 S","SortOrder":0,
          "Views":[{"Id":15160,"Url":"https://www.udottraffic.utah.gov/map/Cctv/15160","Status":"Enabled","Description":""}]}]
        """
        let r = try UDOTCameras.sources(fromJSON: Data(json.utf8), key: "fixture-key")
        XCTAssertEqual(r.sources.count, 1)
        XCTAssertEqual(r.sources[0].state, "UT")
        XCTAssertEqual(r.sources[0].citation.url, UDOTCameras.endpoint)
        XCTAssertEqual(r.sources[0].name, "River Rd · Snapshot")
        XCTAssertFalse(r.sources[0].mayBeAnalysed)
        XCTAssertThrowsError(try UDOTCameras.sources(fromJSON: Data(json.utf8), key: " "))
    }
}
