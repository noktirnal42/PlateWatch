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

    // MARK: - Merging an imported catalogue

    private func make(_ id: String, url: String, confirmed: Bool, side: Int? = nil) -> PublicFeedSource {
        let terms = confirmed
            ? FeedTerms(licenseClass: .publicDomain, termsURL: URL(string: "https://example.gov/terms")!,
                        termsReadOn: Date(timeIntervalSince1970: 1_800_000_000), attribution: "City", automatedUseAllowed: true)
            : FeedTerms(licenseClass: .publicDomain)
        return try! PublicFeedSource(
            id: UUID(uuidString: "00000000-0000-0000-0000-00000000000\(id)")!, name: "cam \(id)", url: URL(string: url)!,
            kind: .snapshotJPEG, refreshInterval: 30, geohash6: "9v6kpv",
            citation: SourceCitation(sourceType: .openDataPortal), terms: terms, nativeLongSide: side)
    }

    /// Re-importing must never undo a person's decision.
    func testMergeKeepsRecordedTermsAndAddsNewSources() {
        let existing = FeedCatalogue(sources: [make("1", url: "https://cctv.example.gov/1.jpg", confirmed: true, side: 1920)])
        let imported = [make("1", url: "https://cctv.example.gov/1-new.jpg", confirmed: false),   // same camera, URL refreshed
                        make("2", url: "https://cctv.example.gov/2.jpg", confirmed: false)]       // new camera
        let merged = existing.merged(with: imported)
        XCTAssertEqual(merged.sources.count, 2)
        let one = merged.sources.first { $0.name == "cam 1" }!
        XCTAssertTrue(one.mayBeAnalysed, "confirmation survives a re-import")
        XCTAssertEqual(one.url.absoluteString, "https://cctv.example.gov/1-new.jpg", "URL refreshed")
        XCTAssertEqual(one.nativeLongSide, 1920)
        XCTAssertFalse(merged.sources.first { $0.name == "cam 2" }!.mayBeAnalysed, "new sources arrive unconfirmed")
    }

    /// The terms a person read applied to the old image host, not to wherever the portal now points.
    func testChangedHostWithdrawsConfirmation() {
        let existing = FeedCatalogue(sources: [make("1", url: "https://cctv.example.gov/1.jpg", confirmed: true)])
        let merged = existing.merged(with: [make("1", url: "https://other-vendor.example.com/1.jpg", confirmed: false)])
        XCTAssertFalse(merged.sources[0].mayBeAnalysed)
        XCTAssertNotNil(merged.sources[0].terms.termsURL, "the recorded terms page is kept for the reviewer to re-check")
    }

    /// A portal outage returns an empty list; that must not delete the catalogue.
    func testSourcesMissingFromTheImportAreKept() {
        let existing = FeedCatalogue(sources: [make("1", url: "https://cctv.example.gov/1.jpg", confirmed: true)])
        XCTAssertEqual(existing.merged(with: []), existing)
    }
}
