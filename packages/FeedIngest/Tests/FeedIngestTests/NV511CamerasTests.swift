import Foundation
import XCTest
@testable import FeedIngest

final class NV511CamerasTests: XCTestCase {
    private let fixture = """
    [{"Id":1,"Roadway":"Synthetic intersection","Latitude":39.47,"Longitude":-119.79,
      "Views":[
        {"Id":11,"Status":"Enabled","Description":"North", "Url":"https://www.nvroads.com/map/Cctv/11", "VideoUrl":"https://video.example.gov/north/playlist.m3u8"},
        {"Id":12,"Status":"Enabled","Description":"South", "Url":"https://www.nvroads.com/map/Cctv/12", "VideoUrl":"https://video.example.gov/south/playlist.m3u8"},
        {"Id":13,"Status":"Disabled","Url":"https://www.nvroads.com/map/Cctv/13", "VideoUrl":"https://video.example.gov/off.m3u8"}]}]
    """
    func testAllEnabledViewsKeepSeparateSnapshotsAndStreams() throws {
        let result = try NV511Cameras.sources(fromJSON: Data(fixture.utf8), key: "fixture-secret")
        XCTAssertEqual(result.sources.count, 4)
        XCTAssertEqual(Set(result.sources.map(\.id)).count, 4)
        XCTAssertEqual(result.sources.filter { $0.kind == .hls }.count, 2)
        XCTAssertTrue(result.sources.allSatisfy { $0.state == "NV" && !$0.mayBeAnalysed })
        XCTAssertTrue(result.sources.allSatisfy { $0.citation.url == NV511Cameras.endpoint })
        XCTAssertEqual(result.sources, try NV511Cameras.sources(fromJSON: Data(fixture.utf8), key: "fixture-secret", retrievedAt: result.sources[0].citation.retrievedAt).sources)
        let encoded = String(decoding: try FeedCatalogue(sources: result.sources).encoded(), as: UTF8.self)
        XCTAssertFalse(encoded.contains("fixture-secret"))
    }
    func testInvalidAndInsecureMediaAreRejected() throws {
        let json = fixture.replacingOccurrences(of: "https://", with: "http://")
        let result = try NV511Cameras.sources(fromJSON: Data(json.utf8), key: "fixture")
        XCTAssertTrue(result.sources.isEmpty)
        XCTAssertEqual(result.skippedCount, 4)
        XCTAssertThrowsError(try NV511Cameras.sources(fromJSON: Data("{}".utf8), key: "fixture"))
        XCTAssertThrowsError(try NV511Cameras.sources(fromJSON: Data("[]".utf8), key: " \n"))
    }
    func testOptionalSavedLiveCatalogue() throws {
        guard let path = ProcessInfo.processInfo.environment["PLATEWATCH_NV511_FIXTURE_PATH"] else { throw XCTSkip("Opt-in saved official API response") }
        let result = try NV511Cameras.sources(fromJSON: Data(contentsOf: URL(fileURLWithPath: path)), key: "not-persisted")
        XCTAssertGreaterThan(result.sources.count, 600)
        XCTAssertGreaterThan(result.sources.filter { $0.kind == .hls }.count, 0)
        XCTAssertTrue(result.sources.allSatisfy { !$0.mayBeAnalysed })
        print("Saved NV511 response: \(result.sources.filter { $0.kind == .snapshotJPEG }.count) snapshots, \(result.sources.filter { $0.kind == .hls }.count) HLS streams; all await human review")
    }

}
