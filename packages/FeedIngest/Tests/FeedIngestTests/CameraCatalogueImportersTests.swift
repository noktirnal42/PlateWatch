import XCTest
@testable import FeedIngest

final class CameraCatalogueImportersTests: XCTestCase {
    private let op = CameraCatalogueImporters.Operator(
        datasetURL: URL(string: "https://example.gov/cameras")!, attribution: "Example DOT", licenseClass: .openLicence)

    func testNewMexicoUsesOfficialHTTPSProxyAndSkipsNonFixedSources() throws {
        let data = Data(#"{"cameraInfo":[{"name":"I25@View & 1","title":"Test view","lat":35.5,"lon":-106.2,"enabled":true,"mobile":false,"videoServer":"rtmp://video.nmroads.com/nmroads"},{"name":"mobile","enabled":true,"mobile":true},{"name":"offline","enabled":false}]}"#.utf8)
        let result = try CameraCatalogueImporters.newMexicoRoads(data, operator: op)
        let source = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.skippedCount, 2)
        XCTAssertEqual(source.kind, .snapshotJPEG)
        XCTAssertEqual(source.url.host, "servicev5.nmroads.com")
        XCTAssertEqual(URLComponents(url: source.url, resolvingAgainstBaseURL: false)?.queryItems?.last?.value, "I25@View & 1")
        XCTAssertFalse(source.mayBeAnalysed)
        XCTAssertFalse(source.geohash6.isEmpty)
    }

    func testUtahRetiredHostMigrationPreservesPositionAndPendingTerms() throws {
        let data = Data(#"{"features":[{"attributes":{"OBJECTID":1,"NAME":"Test UDOT view","URL":"http://www.commuterlink.utah.gov/1_devices/aux14864.jpeg"},"geometry":{"x":-113.614,"y":37.007}}]}"#.utf8)
        let result = try CameraCatalogueImporters.utahTraffic(data, operator: .init(
            datasetURL: URL(string: "https://central.udot.utah.gov/server/rest/services/TOC_Devices/MapServer/0")!,
            attribution: "UDOT", licenseClass: .unknown))
        XCTAssertEqual(result.sources.count, 1)
        XCTAssertEqual(result.sources.first?.url.absoluteString, "https://udottraffic.utah.gov/1_devices/aux14864.jpeg")
        XCTAssertFalse(try XCTUnwrap(result.sources.first).mayBeAnalysed)
        XCTAssertFalse(try XCTUnwrap(result.sources.first).geohash6.isEmpty)
    }

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

final class OregonInventoryTests: XCTestCase {
    private let op = CameraCatalogueImporters.Operator(
        datasetURL: URL(string: "https://tripcheck.com/Scripts/map/data/cctvinventory.js")!,
        attribution: "Camera courtesy of ODOT / TripCheck", licenseClass: .unknown, refreshInterval: 300)

    func testOfficialInventoryUsesAttributeCoordinatesAndPreservesFilename() throws {
        let data = Data(#"{"features":[{"attributes":{"cameraId":277,"publishedImageId":392,"filename":"I-5 Bridge North.jpg","title":"Bridge","latitude":46.18785,"longitude":-123.85347},"geometry":{"x":-13787305,"y":5810503}}]}"#.utf8)
        let result = try CameraCatalogueImporters.oregonTripCheck(data, operator: op)
        let source = try XCTUnwrap(result.sources.first)
        XCTAssertEqual(source.url.absoluteString, "https://www.tripcheck.com/RoadCams/cams/I-5%20Bridge%20North.jpg")
        XCTAssertEqual(source.refreshInterval, 300)
        XCTAssertNotNil(source.citation.url)
        XCTAssertFalse(source.mayBeAnalysed)
        XCTAssertEqual(result.skippedCount, 0)
        let repeated = try CameraCatalogueImporters.oregonTripCheck(data, operator: op)
        XCTAssertEqual(source.id, repeated.sources.first?.id)
    }

    func testRejectsTraversalAndKeepsDifferentViewsOfSameCamera() throws {
        let data = Data(#"{"features":[{"attributes":{"cameraId":1,"publishedImageId":11,"filename":"a.jpg","latitude":45,"longitude":-123}},{"attributes":{"cameraId":1,"publishedImageId":12,"filename":"b.jpg","latitude":45,"longitude":-123}},{"attributes":{"cameraId":2,"publishedImageId":13,"filename":"../bad.jpg","latitude":45,"longitude":-123}}]}"#.utf8)
        let result = try CameraCatalogueImporters.oregonTripCheck(data, operator: op)
        XCTAssertEqual(result.sources.count, 2)
        XCTAssertEqual(Set(result.sources.map(\.id)).count, 2)
        XCTAssertEqual(result.skippedCount, 1)
    }
}
