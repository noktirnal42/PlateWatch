import XCTest
import PlateKit
@testable import FeedIngest

final class FeedCatalogueTests: XCTestCase {

    private func source(_ name: String, confirmed: Bool) -> PublicFeedSource {
        let terms = confirmed
            ? FeedTerms(licenseClass: .publicDomain, termsURL: URL(string: "https://example.gov/terms")!,
                        termsReadOn: Date(timeIntervalSince1970: 1_800_000_000), attribution: "City", automatedUseAllowed: true)
            : FeedTerms(licenseClass: .publicDomain)
        return try! PublicFeedSource(name: name, url: URL(string: "https://example.gov/\(name).jpg")!, kind: .snapshotJPEG,
                                     refreshInterval: 30, geohash6: "9v6kpv",
                                     citation: SourceCitation(sourceType: .openDataPortal, url: URL(string: "https://example.gov/data")!,
                                                           retrievedAt: Date(timeIntervalSince1970: 1_800_000_000)),
                                     terms: terms, nativeLongSide: 1920, locationConfidence: .surveyed)
    }

    /// An imported catalogue is carried in full but only the human-cleared sources may run.
    func testOnlyConfirmedSourcesAreRunnable() {
        let catalogue = FeedCatalogue(sources: [source("a", confirmed: true), source("b", confirmed: false), source("c", confirmed: false)])
        XCTAssertEqual(catalogue.runnable.map(\.name), ["a"])
        XCTAssertEqual(catalogue.awaitingTerms.map(\.name), ["b", "c"])
        XCTAssertTrue(FeedCatalogue().runnable.isEmpty)
    }

    func testRoundTripThroughDiskKeepsEverything() throws {
        let original = FeedCatalogue(sources: [source("a", confirmed: true), source("b", confirmed: false)])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pw-feeds-\(UUID().uuidString)/feeds.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try original.write(to: url)                                   // creates the folder
        let loaded = try FeedCatalogue.load(from: url)
        XCTAssertEqual(loaded, original)
        XCTAssertEqual(loaded.runnable.count, 1)
        let text = try XCTUnwrap(String(data: Data(contentsOf: url), encoding: .utf8))
        XCTAssertTrue(text.contains("2027-01-15T08:00:00Z"), "terms-read date is ISO-8601 in the file")
        XCTAssertTrue(text.contains("https://example.gov/a.jpg"), "slashes are not escaped")
    }

    func testEncodingIsStable() throws {
        let c = FeedCatalogue(sources: [source("a", confirmed: true)])
        XCTAssertEqual(try c.encoded(), try c.encoded(), "sorted keys: re-saving an unchanged catalogue does not churn the file")
    }

    func testMissingOrCorruptFileThrows() {
        XCTAssertThrowsError(try FeedCatalogue.load(from: URL(fileURLWithPath: "/nonexistent/feeds.json")))
        XCTAssertThrowsError(try FeedCatalogue.decode(Data("not json".utf8)))
    }
}
