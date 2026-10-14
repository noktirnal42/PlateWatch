import XCTest
@testable import FeedIngest

final class CameraCatalogueImportersTests: XCTestCase {
    private let op = CameraCatalogueImporters.Operator(
        datasetURL: URL(string: "https://example.gov/cameras")!, attribution: "Example DOT", licenseClass: .openLicence)

    func testArcGISImportsAndFlagsPaging() throws {
        let json = #"""
        {"exceededTransferLimit": true, "features": [
          {"attributes": {"OBJECTID": 7, "CameraTitle": "I-5 at Pine", "ImageURL": "https://img.example.gov/7.jpg"}, "geometry": {"x": -122.33, "y": 47.61}},
          {"attributes": {"OBJECTID": 8, "CameraTitle": "Plain http", "ImageURL": "http://img.example.gov/8.jpg"}, "geometry": {"x": -122.3, "y": 47.6}},
          {"attributes": {"OBJECTID": 9, "CameraTitle": "No image", "ImageURL": ""}, "geometry": {"x": -122.3, "y": 47.6}},
          {"attributes": {"OBJECTID": 10, "CameraTitle": "Null island", "ImageURL": "https://img.example.gov/10.jpg"}, "geometry": {"x": 0, "y": 0}}
        ]}
        """#
        let (result, more) = try CameraCatalogueImporters.arcGIS(Data(json.utf8),
            fields: .init(name: "CameraTitle", image: "ImageURL", id: "OBJECTID"), operator: op)
        XCTAssertTrue(more)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources[0].name, "I-5 at Pine")
        XCTAssertEqual(result.sources[0].geohash6.count, 6)
        XCTAssertFalse(result.sources[0].terms.automatedUseAllowed, "imports are never pre-confirmed")
        XCTAssertFalse(result.sources[0].mayBeAnalysed)
        XCTAssertEqual(Set(result.skipReasons.map(\.reason)), [.nonHTTPSURL, .missingImageURL, .zeroCoordinates])
    }

    func testArcGISAttributeCoordinatesAndStableIDs() throws {
        let json = #"{"features":[{"attributes":{"device_id":"a1","Desc_":"Camera","ImageURL":"https://i.example.gov/a1.jpg","latitude":41.6,"longitude":-93.6}}]}"#
        let fields = CameraCatalogueImporters.ArcGISFields(name: "Desc_", image: "ImageURL", id: "device_id", latitude: "latitude", longitude: "longitude")
        let a = try CameraCatalogueImporters.arcGIS(Data(json.utf8), fields: fields, operator: op).result.sources
        let b = try CameraCatalogueImporters.arcGIS(Data(json.utf8), fields: fields, operator: op).result.sources
        XCTAssertEqual(a.count, 1)
        XCTAssertEqual(a[0].id, b[0].id, "the same camera keeps the same id across imports")
    }

    func testCaltransKeepsInServiceHTTPSOnly() throws {
        let json = #"""
        {"data": [
          {"cctv": {"index": "1", "inService": "true", "location": {"locationName": "SR-99", "latitude": "38.5", "longitude": "-121.5"},
                    "imageData": {"static": {"currentImageURL": "https://cwwp2.dot.ca.gov/data/d3/cctv/image/a.jpg"}}}},
          {"cctv": {"index": "2", "inService": "false", "location": {"locationName": "Off", "latitude": "38.5", "longitude": "-121.5"},
                    "imageData": {"static": {"currentImageURL": "https://cwwp2.dot.ca.gov/b.jpg"}}}},
          {"cctv": {"index": "3", "inService": "true", "location": {"locationName": "No img", "latitude": "38.5", "longitude": "-121.5"},
                    "imageData": {"static": {"currentImageURL": "Not Reported"}}}}
        ]}
        """#
        let r = try CameraCatalogueImporters.caltrans(Data(json.utf8), district: 3, operator: op)
        XCTAssertEqual(r.sources.map(\.name), ["SR-99"])
        XCTAssertEqual(Set(r.skipReasons.map(\.reason)), [.notTurnedOn, .missingImageURL])
    }

    func testDriveBCResolvesRelativeImageURLs() throws {
        let json = #"{"webcams":[{"id":12,"name":"Hwy 1","is_on":true,"location":{"coordinates":[-123.1,49.2]},"links":{"imageDisplay":"/images/12.jpg"}},{"id":13,"name":"Off","is_on":false}]}"#
        let r = try CameraCatalogueImporters.driveBC(Data(json.utf8), operator: op)
        XCTAssertEqual(r.sources.count, 1)
        XCTAssertEqual(r.sources[0].url.absoluteString, "https://www.drivebc.ca/images/12.jpg")
    }

    func testMalformedInputThrows() {
        XCTAssertThrowsError(try CameraCatalogueImporters.caltrans(Data("{}".utf8), district: 1, operator: op))
        XCTAssertThrowsError(try CameraCatalogueImporters.arcGIS(Data("[]".utf8), fields: .init(name: "n", image: "i", id: "d"), operator: op))
    }
}
