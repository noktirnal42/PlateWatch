import XCTest
@testable import FeedIngest
import PlateKit

final class SocrataCameraCatalogueTests: XCTestCase {
    private let datasetURL = URL(string: "https://data.austintexas.gov/resource/b4k4-adkb.json")!
    private let retrievedAt = Date(timeIntervalSince1970: 1_760_000_000)

    // Trimmed 5-record sample from /private/tmp/pw-feeds/austin5.json
    private let sampleJSON = """
    [
        {"camera_id":"674","location_name":" CESAR CHAVEZ ST / 35 SVRD","camera_status":"TURNED_ON","turn_on_date":"2020-03-19T05:00:00.000Z","camera_mfg":"Wisenet","atd_location_id":"LOC16-000675","signal_eng_area":"CENTRAL","council_district":"3","jurisdiction_label":"AUSTIN FULL PURPOSE","location_type":"ROADWAY","primary_st_block":"800","primary_st":" CESAR CHAVEZ ST","cross_st_block":"100","cross_st":"IH 35 SVRD","coa_intersection_id":"5158088","modified_date":"2026-09-24T21:58:00.000Z","screenshot_address":"https://cctv.austinmobility.io/image/674.jpg","funding":"None Identified","id":"5d40501e9442f20010304da5","location":{"type":"Point","coordinates":[-97.735786,30.260996]}},
        {"camera_id":"675","location_name":" CESAR CHAVEZ ST / SAN ANTONIO ST","camera_status":"TURNED_ON","turn_on_date":"2025-07-18T05:00:00.000Z","camera_mfg":"Wisenet","atd_location_id":"LOC16-001365","signal_eng_area":"CENTRAL","council_district":"9","jurisdiction_label":"AUSTIN FULL PURPOSE","location_type":"ROADWAY","primary_st_block":"400","primary_st":" CESAR CHAVEZ ST","cross_st_block":"100","cross_st":" SAN ANTONIO ST","coa_intersection_id":"5156008","modified_date":"2026-03-24T15:35:00.000Z","screenshot_address":"https://cctv.austinmobility.io/image/675.jpg","funding":"None Identified","id":"5d405175a46d86001218c73d","location":{"type":"Point","coordinates":[-97.749115,30.264656]}},
        {"camera_id":"676","location_name":" LAMAR BLVD / TOOMEY RD","camera_status":"TURNED_ON","turn_on_date":"2019-10-01T05:00:00.000Z","camera_mfg":"Wisenet","atd_location_id":"LOC16-004980","signal_eng_area":"CENTRAL","council_district":"9","jurisdiction_label":"AUSTIN FULL PURPOSE","location_type":"ROADWAY","primary_st_block":"200","primary_st":" LAMAR BLVD","cross_st_block":"1301","cross_st":" TOOMEY RD","coa_intersection_id":"5154881","modified_date":"2024-09-04T15:33:00.000Z","screenshot_address":"https://cctv.austinmobility.io/image/676.jpg","funding":"None Identified","id":"5d4051d22b8e750011d80c5d","location":{"type":"Point","coordinates":[-97.757907,30.262954]}},
        {"camera_id":"678","location_name":" 15TH ST / NUECES ST","camera_status":"TURNED_ON","turn_on_date":"2025-04-11T05:00:00.000Z","camera_mfg":"Wisenet","atd_location_id":"LOC16-001070","signal_eng_area":"CENTRAL","council_district":"9","jurisdiction_label":"AUSTIN FULL PURPOSE","location_type":"ROADWAY","primary_st_block":"600","primary_st":" 15TH ST","cross_st_block":"1500","cross_st":" NUECES ST","coa_intersection_id":"5156571","modified_date":"2025-04-11T15:20:00.000Z","screenshot_address":"https://cctv.austinmobility.io/image/678.jpg","funding":"None Identified","id":"5d405250bed0b10012e9e355","location":{"type":"Point","coordinates":[-97.745148,30.278534]}},
        {"camera_id":"687","location_name":" 8TH ST / SAN JACINTO BLVD","camera_status":"TURNED_ON","turn_on_date":"2019-08-22T05:00:00.000Z","camera_mfg":"Wisenet","atd_location_id":"LOC16-001395","signal_eng_area":"CENTRAL","council_district":"9","jurisdiction_label":"AUSTIN FULL PURPOSE","location_type":"ROADWAY","primary_st_block":"200","primary_st":" 8TH ST","cross_st_block":"800","cross_st":" SAN JACINTO BLVD","coa_intersection_id":"5157430","modified_date":"2024-08-05T21:08:00.000Z","screenshot_address":"https://cctv.austinmobility.io/image/687.jpg","funding":"None Identified","id":"5d405989c852440011734bc6","location":{"type":"Point","coordinates":[-97.739693,30.269236]}}
    ]
    """

    func testHappyPath() throws {
        let data = sampleJSON.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(
            fromJSON: data,
            datasetURL: datasetURL,
            refreshInterval: 60,
            retrievedAt: retrievedAt
        )

        XCTAssertEqual(result.sources.count, 5)
        XCTAssertEqual(result.skippedCount, 0)
        XCTAssertTrue(result.skipReasons.isEmpty)

        // Check first source fields
        let first = result.sources[0]
        XCTAssertEqual(first.name, "CESAR CHAVEZ ST / 35 SVRD") // trimmed
        XCTAssertEqual(first.url, URL(string: "https://cctv.austinmobility.io/image/674.jpg")!)
        XCTAssertEqual(first.kind, .snapshotJPEG)
        XCTAssertEqual(first.refreshInterval, 60)
        XCTAssertEqual(first.geohash6, "9v6kpu") // Austin, Texas geohash-6 for [-97.735786, 30.260996]
        XCTAssertEqual(first.citation.sourceType, .openDataPortal)
        XCTAssertEqual(first.citation.url, datasetURL)
        XCTAssertEqual(first.citation.retrievedAt, retrievedAt)
        XCTAssertEqual(first.terms.licenseClass, .publicDomain)
        XCTAssertEqual(first.terms.attribution, "City of Austin")
        XCTAssertFalse(first.terms.automatedUseAllowed)
        XCTAssertNil(first.terms.termsURL)
        XCTAssertNil(first.terms.termsReadOn)
        XCTAssertEqual(first.locationConfidence, .surveyed)
        XCTAssertNil(first.nativeLongSide)
        XCTAssertFalse(first.mayBeAnalysed) // automatedUseAllowed is false
        XCTAssertEqual(first.termsNote, "")
    }

    func testGeohashLongitudeLatitudeOrder() throws {
        // The first camera is at [-97.735786, 30.260996] (longitude, latitude)
        // Geohash-6 for Austin, Texas at this location should start with "9v6k"
        let data = sampleJSON.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(
            fromJSON: data,
            datasetURL: datasetURL,
            retrievedAt: retrievedAt
        )

        let firstGeohash = result.sources[0].geohash6
        XCTAssertTrue(firstGeohash.hasPrefix("9v6k"), "Expected geohash to start with '9v6k', got \(firstGeohash)")

        // Verify by computing directly
        let computed = Geohash.encode(latitude: 30.260996, longitude: -97.735786, precision: 6)
        XCTAssertEqual(firstGeohash, computed)
        XCTAssertTrue(computed.hasPrefix("9v6k"))
    }

    func testWhitespaceTrimming() throws {
        let data = sampleJSON.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(
            fromJSON: data,
            datasetURL: datasetURL,
            retrievedAt: retrievedAt
        )

        // All location_names in sample have leading space
        for source in result.sources {
            XCTAssertFalse(source.name.hasPrefix(" "), "Name should not have leading space: '\(source.name)'")
            XCTAssertFalse(source.name.hasSuffix(" "), "Name should not have trailing space: '\(source.name)'")
        }

        // Specific checks
        XCTAssertEqual(result.sources[0].name, "CESAR CHAVEZ ST / 35 SVRD")
        XCTAssertEqual(result.sources[1].name, "CESAR CHAVEZ ST / SAN ANTONIO ST")
    }

    func testSkipNotTurnedOn() throws {
        let json = """
        [
            {"camera_id":"100","location_name":"CAM 1","camera_status":"TURNED_OFF","screenshot_address":"https://example.com/1.jpg","location":{"type":"Point","coordinates":[-97.7,30.2]}},
            {"camera_id":"101","location_name":"CAM 2","camera_status":"MAINTENANCE","screenshot_address":"https://example.com/2.jpg","location":{"type":"Point","coordinates":[-97.7,30.2]}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result.sources.count, 0)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertTrue(result.skipReasons.allSatisfy { $0.reason == .notTurnedOn })
    }

    func testSkipMissingImageURL() throws {
        let json = """
        [
            {"camera_id":"200","location_name":"CAM 1","camera_status":"TURNED_ON","location":{"type":"Point","coordinates":[-97.7,30.2]}},
            {"camera_id":"201","location_name":"CAM 2","camera_status":"TURNED_ON","screenshot_address":"","location":{"type":"Point","coordinates":[-97.7,30.2]}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result.sources.count, 0)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertTrue(result.skipReasons.allSatisfy { $0.reason == .missingImageURL })
    }

    func testSkipInvalidImageURL() throws {
        let json = """
        [
            {"camera_id":"300","location_name":"CAM 1","camera_status":"TURNED_ON","screenshot_address":"https://","location":{"type":"Point","coordinates":[-97.7,30.2]}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result.sources.count, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.skipReasons[0].reason, .invalidImageURL)
    }

    func testSkipNonHTTPSURL() throws {
        let json = """
        [
            {"camera_id":"400","location_name":"CAM 1","camera_status":"TURNED_ON","screenshot_address":"http://example.com/1.jpg","location":{"type":"Point","coordinates":[-97.7,30.2]}},
            {"camera_id":"401","location_name":"CAM 2","camera_status":"TURNED_ON","screenshot_address":"ftp://example.com/2.jpg","location":{"type":"Point","coordinates":[-97.7,30.2]}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result.sources.count, 0)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertTrue(result.skipReasons.allSatisfy { $0.reason == .nonHTTPSURL })
    }

    func testSkipMissingCoordinates() throws {
        let json = """
        [
            {"camera_id":"500","location_name":"CAM 1","camera_status":"TURNED_ON","screenshot_address":"https://example.com/1.jpg"},
            {"camera_id":"501","location_name":"CAM 2","camera_status":"TURNED_ON","screenshot_address":"https://example.com/2.jpg","location":{}},
            {"camera_id":"502","location_name":"CAM 3","camera_status":"TURNED_ON","screenshot_address":"https://example.com/3.jpg","location":{"type":"Point"}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result.sources.count, 0)
        XCTAssertEqual(result.skippedCount, 3)
        XCTAssertTrue(result.skipReasons.allSatisfy { $0.reason == .missingCoordinates })
    }

    func testSkipInvalidCoordinates() throws {
        let json = """
        [
            {"camera_id":"600","location_name":"CAM 1","camera_status":"TURNED_ON","screenshot_address":"https://example.com/1.jpg","location":{"type":"Point","coordinates":[200,30.2]}},
            {"camera_id":"601","location_name":"CAM 2","camera_status":"TURNED_ON","screenshot_address":"https://example.com/2.jpg","location":{"type":"Point","coordinates":[-97.7,100]}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result.sources.count, 0)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertTrue(result.skipReasons.allSatisfy { $0.reason == .invalidCoordinates })
    }

    func testSkipZeroCoordinates() throws {
        let json = """
        [
            {"camera_id":"700","location_name":"CAM 1","camera_status":"TURNED_ON","screenshot_address":"https://example.com/1.jpg","location":{"type":"Point","coordinates":[0,0]}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result.sources.count, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.skipReasons[0].reason, .zeroCoordinates)
    }

    func testSkipDuplicateCameraID() throws {
        let json = """
        [
            {"camera_id":"800","location_name":"CAM 1","camera_status":"TURNED_ON","screenshot_address":"https://example.com/1.jpg","location":{"type":"Point","coordinates":[-97.7,30.2]}},
            {"camera_id":"800","location_name":"CAM 1 DUP","camera_status":"TURNED_ON","screenshot_address":"https://example.com/2.jpg","location":{"type":"Point","coordinates":[-97.8,30.3]}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.skipReasons[0].reason, .duplicateCameraID)
        XCTAssertEqual(result.skipReasons[0].cameraID, "800")
    }

    func testStableIDsAcrossImports() throws {
        let data = sampleJSON.data(using: .utf8)!
        let result1 = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)
        let result2 = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        XCTAssertEqual(result1.sources.count, result2.sources.count)
        for (s1, s2) in zip(result1.sources, result2.sources) {
            XCTAssertEqual(s1.id, s2.id, "Stable UUID mismatch for camera \(s1.name)")
        }
    }

    func testRefreshIntervalBelowFloor() throws {
        let json = """
        [
            {"camera_id":"900","location_name":"CAM 1","camera_status":"TURNED_ON","screenshot_address":"https://example.com/1.jpg","location":{"type":"Point","coordinates":[-97.7,30.2]}}
        ]
        """
        let data = json.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(
            fromJSON: data,
            datasetURL: datasetURL,
            refreshInterval: 0.5, // below 1 second floor
            retrievedAt: retrievedAt
        )

        XCTAssertEqual(result.sources.count, 0)
        XCTAssertEqual(result.skippedCount, 1)
        XCTAssertEqual(result.skipReasons[0].reason, .refreshIntervalTooAggressive)
    }

    func testMalformedJSONThrows() throws {
        let json = "not valid json"
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)) { error in
            // ImportError.malformedJSON is private, so we just verify an error is thrown
            XCTAssertNotNil(error)
        }
    }

    func testNonArrayJSONThrows() throws {
        let json = "{\"camera_id\": \"123\"}"
        let data = json.data(using: .utf8)!

        XCTAssertThrowsError(try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt))
    }

    func testMayBeAnalysedIsFalse() throws {
        let data = sampleJSON.data(using: .utf8)!
        let result = try SocrataCameraCatalogue.sources(fromJSON: data, datasetURL: datasetURL, retrievedAt: retrievedAt)

        for source in result.sources {
            XCTAssertFalse(source.mayBeAnalysed, "Source \(source.name) should not be analysable (automatedUseAllowed=false)")
        }
    }

    // MARK: - Review additions (Claude)

    private func record(_ id: String?, name: String? = "MAIN ST", extra: String = "") -> String {
        let idPart = id.map { "\"camera_id\":\"\($0)\"," } ?? ""
        let namePart = name.map { "\"location_name\":\"\($0)\"," } ?? ""
        return "{\(idPart)\(namePart)\"camera_status\":\"TURNED_ON\",\"screenshot_address\":\"https://cctv.example.gov/image/1.jpg\",\"location\":{\"type\":\"Point\",\"coordinates\":[-97.7,30.2]}\(extra)}"
    }
    private let dataset = URL(string: "https://data.example.gov/resource/abcd-1234")!

    /// A record with no camera id used to vanish without a trace: the importer must account for every record.
    func testRecordWithoutCameraIDIsReportedNotSilentlyDropped() throws {
        let json = "[\(record("1")),\(record(nil)),\(record(""))]"
        let result = try SocrataCameraCatalogue.sources(fromJSON: Data(json.utf8), datasetURL: dataset)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(result.skipReasons.map(\.reason), [.missingCameraID, .missingCameraID])
    }

    /// The importer is generic: the credit line is the operator's, supplied by the caller.
    func testAttributionIsConfigurable() throws {
        let result = try SocrataCameraCatalogue.sources(fromJSON: Data("[\(record("1"))]".utf8), datasetURL: dataset,
                                                        attribution: "Example County DOT")
        XCTAssertEqual(result.sources.first?.terms.attribution, "Example County DOT")
        XCTAssertFalse(try XCTUnwrap(result.sources.first).mayBeAnalysed, "still unconfirmed")
    }

    func testEmptyNameFallsBackToTheCameraID() throws {
        let result = try SocrataCameraCatalogue.sources(
            fromJSON: Data("[\(record("42", name: "   ")),\(record("43", name: nil))]".utf8), datasetURL: dataset)
        XCTAssertEqual(result.sources.map(\.name), ["Camera 42", "Camera 43"])
    }
}
