import Foundation
import XCTest
@testable import FeedIngest
import PlateKit

final class FeedTermsReviewTests: XCTestCase {
    private let citation = SourceCitation(
        sourceType: .openDataPortal,
        url: URL(string: "https://data.austintexas.gov/resource/b4k4-adkb.json")!,
        retrievedAt: Date(timeIntervalSince1970: 1_760_000_000)
    )

    private func makeSource(
        id: UUID = UUID(),
        host: String = "cctv.austinmobility.io",
        terms: FeedTerms = .unknown
    ) -> PublicFeedSource {
        try! PublicFeedSource(
            id: id,
            name: "Test Camera",
            url: URL(string: "https://\(host)/image/1.jpg")!,
            kind: .snapshotJPEG,
            refreshInterval: 60,
            geohash6: "9v6kpu",
            citation: citation,
            terms: terms
        )
    }

    private func makeCatalogue(sources: [PublicFeedSource] = []) -> FeedCatalogue {
        FeedCatalogue(sources: sources)
    }

    // MARK: - hosts()

    func testHostsSummary() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()
        let id4 = UUID()

        let sources = [
            makeSource(id: id1, host: "cctv.austinmobility.io", terms: .init(licenseClass: .publicDomain, termsURL: URL(string: "https://example.com/terms")!, termsReadOn: Date(), attribution: "City", automatedUseAllowed: true)),
            makeSource(id: id2, host: "cctv.austinmobility.io", terms: .unknown),
            makeSource(id: id3, host: "other.example.com", terms: .init(licenseClass: .publicDomain, termsURL: URL(string: "https://example.com/terms")!, termsReadOn: Date(), attribution: "Other", automatedUseAllowed: true)),
            makeSource(id: id4, host: "other.example.com", terms: .unknown),
        ]
        let catalogue = makeCatalogue(sources: sources)
        let summaries = catalogue.hosts()

        XCTAssertEqual(summaries.count, 2)

        let austin = summaries.first { $0.host == "cctv.austinmobility.io" }!
        XCTAssertEqual(austin.totalCount, 2)
        XCTAssertEqual(austin.confirmedCount, 1)

        let other = summaries.first { $0.host == "other.example.com" }!
        XCTAssertEqual(other.totalCount, 2)
        XCTAssertEqual(other.confirmedCount, 1)
    }

    func testHostsSummaryCaseInsensitive() {
        let id1 = UUID()
        let id2 = UUID()

        let sources = [
            makeSource(id: id1, host: "CCTV.AUSTINMOBILITY.IO", terms: .init(licenseClass: .publicDomain, termsURL: URL(string: "https://example.com/terms")!, termsReadOn: Date(), attribution: "City", automatedUseAllowed: true)),
            makeSource(id: id2, host: "cctv.austinmobility.io", terms: .unknown),
        ]
        let catalogue = makeCatalogue(sources: sources)
        let summaries = catalogue.hosts()

        XCTAssertEqual(summaries.count, 1)
        XCTAssertEqual(summaries[0].totalCount, 2)
        XCTAssertEqual(summaries[0].confirmedCount, 1)
        XCTAssertEqual(summaries[0].host, "cctv.austinmobility.io")
    }

    func testHostsEmptyCatalogue() {
        let catalogue = makeCatalogue()
        let summaries = catalogue.hosts()
        XCTAssertTrue(summaries.isEmpty)
    }

    // MARK: - confirmingTerms(forHost:)

    func testConfirmingTermsForHostSuccess() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let sources = [
            makeSource(id: id1, host: "cctv.austinmobility.io"),
            makeSource(id: id2, host: "cctv.austinmobility.io"),
            makeSource(id: id3, host: "other.example.com"),
        ]
        let catalogue = makeCatalogue(sources: sources)

        let termsURL = URL(string: "https://cctv.austinmobility.io/terms")!
        let newCatalogue = try! catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "City of Austin",
            now: Date(timeIntervalSince1970: 2_000_000_000)
        )

        // Both Austin sources should be confirmed
        let austinSources = newCatalogue.sources.filter { $0.url.host?.lowercased() == "cctv.austinmobility.io" }
        XCTAssertEqual(austinSources.count, 2)
        for source in austinSources {
            XCTAssertTrue(source.mayBeAnalysed)
            XCTAssertEqual(source.terms.licenseClass, .publicDomain)
            XCTAssertEqual(source.terms.termsURL, termsURL)
            XCTAssertEqual(source.terms.termsReadOn, Date(timeIntervalSince1970: 2_000_000_000))
            XCTAssertEqual(source.terms.attribution, "City of Austin")
            XCTAssertTrue(source.terms.automatedUseAllowed)
        }

        // Other host should be untouched
        let otherSources = newCatalogue.sources.filter { $0.url.host?.lowercased() == "other.example.com" }
        XCTAssertEqual(otherSources.count, 1)
        XCTAssertFalse(otherSources[0].mayBeAnalysed)
        XCTAssertEqual(otherSources[0].terms, .unknown)
    }

    func testConfirmingTermsForHostCaseInsensitive() {
        let id1 = UUID()
        let sources = [makeSource(id: id1, host: "CCTV.AUSTINMOBILITY.IO")]
        let catalogue = makeCatalogue(sources: sources)

        let termsURL = URL(string: "https://example.com/terms")!
        let newCatalogue = try! catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "City of Austin"
        )

        XCTAssertTrue(newCatalogue.sources[0].mayBeAnalysed)
    }

    func testConfirmingTermsForHostNoSourcesForHost() {
        let catalogue = makeCatalogue(sources: [makeSource(host: "cctv.austinmobility.io")])

        let termsURL = URL(string: "https://example.com/terms")!
        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forHost: "nonexistent.example.com",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "Test"
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .noSourcesForHost)
        }
    }

    func testConfirmingTermsForHostInsecureTermsURL() {
        let catalogue = makeCatalogue(sources: [makeSource(host: "cctv.austinmobility.io")])

        // HTTP URL
        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: URL(string: "http://example.com/terms")!,
            attribution: "Test"
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .insecureTermsURL)
        }

        // No host
        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: URL(string: "https:///terms")!,
            attribution: "Test"
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .insecureTermsURL)
        }
    }

    func testConfirmingTermsForHostLicenseClassNotUsable() {
        let catalogue = makeCatalogue(sources: [makeSource(host: "cctv.austinmobility.io")])

        let termsURL = URL(string: "https://example.com/terms")!

        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .unknown,
            termsURL: termsURL,
            attribution: "Test"
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .licenceClassNotUsable)
        }

        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .askFirst,
            termsURL: termsURL,
            attribution: "Test"
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .licenceClassNotUsable)
        }
    }

    func testConfirmingTermsForHostAttributionRequired() {
        let catalogue = makeCatalogue(sources: [makeSource(host: "cctv.austinmobility.io")])

        let termsURL = URL(string: "https://example.com/terms")!

        // openLicence requires attribution
        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .openLicence,
            termsURL: termsURL,
            attribution: ""
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .attributionRequired)
        }

        // permissioned requires attribution
        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .permissioned,
            termsURL: termsURL,
            attribution: "   "
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .attributionRequired)
        }

        // publicDomain does NOT require attribution
        let newCat = try! catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: ""
        )
        XCTAssertTrue(newCat.sources[0].mayBeAnalysed)

        // keyed does NOT require attribution
        let newCat2 = try! catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .keyed,
            termsURL: termsURL,
            attribution: ""
        )
        XCTAssertTrue(newCat2.sources[0].mayBeAnalysed)
    }

    func testConfirmingTermsForHostKeepsExistingAttributionIfNewEmptyAndClassDoesNotRequire() {
        let id = UUID()
        let source = makeSource(
            id: id,
            host: "cctv.austinmobility.io",
            terms: .init(licenseClass: .publicDomain, termsURL: URL(string: "https://old.com/terms")!, termsReadOn: Date(), attribution: "Old Attribution", automatedUseAllowed: false)
        )
        let catalogue = makeCatalogue(sources: [source])

        let termsURL = URL(string: "https://new.com/terms")!
        let newCatalogue = try! catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "" // empty, but class doesn't require it
        )

        // Should keep the old attribution
        XCTAssertEqual(newCatalogue.sources[0].terms.attribution, "Old Attribution")
    }

    func testConfirmingTermsForHostUpdatesAttributionWhenProvided() {
        let id = UUID()
        let source = makeSource(
            id: id,
            host: "cctv.austinmobility.io",
            terms: .init(licenseClass: .publicDomain, termsURL: URL(string: "https://old.com/terms")!, termsReadOn: Date(), attribution: "Old Attribution", automatedUseAllowed: false)
        )
        let catalogue = makeCatalogue(sources: [source])

        let termsURL = URL(string: "https://new.com/terms")!
        let newCatalogue = try! catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "New Attribution"
        )

        XCTAssertEqual(newCatalogue.sources[0].terms.attribution, "New Attribution")
    }

    func testConfirmingTermsForHostDoesNotMutateOriginal() {
        let id = UUID()
        let source = makeSource(id: id, host: "cctv.austinmobility.io")
        let catalogue = makeCatalogue(sources: [source])

        let termsURL = URL(string: "https://example.com/terms")!
        let _ = try! catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "Test"
        )

        // Original should be unchanged
        XCTAssertFalse(catalogue.sources[0].mayBeAnalysed)
    }

    // MARK: - confirmingTerms(forSourceID:)

    func testConfirmingTermsForSourceIDSuccess() {
        let id = UUID()
        let source = makeSource(id: id, host: "cctv.austinmobility.io")
        let catalogue = makeCatalogue(sources: [source])

        let termsURL = URL(string: "https://example.com/terms")!
        let newCatalogue = try! catalogue.confirmingTerms(
            forSourceID: id,
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "Test"
        )

        XCTAssertTrue(newCatalogue.sources[0].mayBeAnalysed)
        XCTAssertEqual(newCatalogue.sources[0].terms.termsURL, termsURL)
    }

    func testConfirmingTermsForSourceIDUnknownSource() {
        let catalogue = makeCatalogue(sources: [makeSource(host: "cctv.austinmobility.io")])

        let termsURL = URL(string: "https://example.com/terms")!
        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forSourceID: UUID(),
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "Test"
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .unknownSource)
        }
    }

    func testConfirmingTermsForSourceIDSameValidations() {
        let id = UUID()
        let catalogue = makeCatalogue(sources: [makeSource(id: id, host: "cctv.austinmobility.io")])

        let termsURL = URL(string: "https://example.com/terms")!

        // Test insecure URL
        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forSourceID: id,
            licenseClass: .publicDomain,
            termsURL: URL(string: "http://example.com/terms")!,
            attribution: "Test"
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .insecureTermsURL)
        }

        // Test license class
        XCTAssertThrowsError(try catalogue.confirmingTerms(
            forSourceID: id,
            licenseClass: .askFirst,
            termsURL: termsURL,
            attribution: "Test"
        )) { error in
            XCTAssertEqual(error as? FeedTermsReviewError, .licenceClassNotUsable)
        }
    }

    // MARK: - revokingConfirmation(forHost:)

    func testRevokingConfirmationForHost() {
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        let confirmedTerms = FeedTerms(
            licenseClass: .publicDomain,
            termsURL: URL(string: "https://example.com/terms")!,
            termsReadOn: Date(timeIntervalSince1970: 2_000_000_000),
            attribution: "City of Austin",
            automatedUseAllowed: true
        )

        let sources = [
            makeSource(id: id1, host: "cctv.austinmobility.io", terms: confirmedTerms),
            makeSource(id: id2, host: "cctv.austinmobility.io", terms: confirmedTerms),
            makeSource(id: id3, host: "other.example.com", terms: confirmedTerms),
        ]
        let catalogue = makeCatalogue(sources: sources)

        let newCatalogue = catalogue.revokingConfirmation(forHost: "cctv.austinmobility.io")

        // Austin sources should have automatedUseAllowed = false but keep terms
        let austinSources = newCatalogue.sources.filter { $0.url.host?.lowercased() == "cctv.austinmobility.io" }
        for source in austinSources {
            XCTAssertFalse(source.mayBeAnalysed)
            XCTAssertFalse(source.terms.automatedUseAllowed)
            XCTAssertEqual(source.terms.termsURL, URL(string: "https://example.com/terms")!)
            XCTAssertEqual(source.terms.termsReadOn, Date(timeIntervalSince1970: 2_000_000_000))
            XCTAssertEqual(source.terms.attribution, "City of Austin")
            XCTAssertEqual(source.terms.licenseClass, .publicDomain)
        }

        // Other host should be untouched
        let otherSources = newCatalogue.sources.filter { $0.url.host?.lowercased() == "other.example.com" }
        XCTAssertTrue(otherSources[0].mayBeAnalysed)
        XCTAssertTrue(otherSources[0].terms.automatedUseAllowed)
    }

    func testRevokingConfirmationForHostCaseInsensitive() {
        let id = UUID()
        let confirmedTerms = FeedTerms(
            licenseClass: .publicDomain,
            termsURL: URL(string: "https://example.com/terms")!,
            termsReadOn: Date(),
            attribution: "Test",
            automatedUseAllowed: true
        )
        let catalogue = makeCatalogue(sources: [makeSource(id: id, host: "CCTV.AUSTINMOBILITY.IO", terms: confirmedTerms)])

        let newCatalogue = catalogue.revokingConfirmation(forHost: "cctv.austinmobility.io")

        XCTAssertFalse(newCatalogue.sources[0].mayBeAnalysed)
    }

    func testRevokingConfirmationForHostNoMatchReturnsSame() {
        let id = UUID()
        let confirmedTerms = FeedTerms(
            licenseClass: .publicDomain,
            termsURL: URL(string: "https://example.com/terms")!,
            termsReadOn: Date(),
            attribution: "Test",
            automatedUseAllowed: true
        )
        let catalogue = makeCatalogue(sources: [makeSource(id: id, host: "cctv.austinmobility.io", terms: confirmedTerms)])

        let newCatalogue = catalogue.revokingConfirmation(forHost: "nonexistent.example.com")

        // Should be unchanged
        XCTAssertTrue(newCatalogue.sources[0].mayBeAnalysed)
        XCTAssertEqual(newCatalogue.sources.count, catalogue.sources.count)
    }

    // MARK: - revokingConfirmation(forSourceID:)

    func testRevokingConfirmationForSourceID() {
        let id = UUID()
        let confirmedTerms = FeedTerms(
            licenseClass: .publicDomain,
            termsURL: URL(string: "https://example.com/terms")!,
            termsReadOn: Date(timeIntervalSince1970: 2_000_000_000),
            attribution: "City of Austin",
            automatedUseAllowed: true
        )
        let catalogue = makeCatalogue(sources: [makeSource(id: id, host: "cctv.austinmobility.io", terms: confirmedTerms)])

        let newCatalogue = catalogue.revokingConfirmation(forSourceID: id)

        XCTAssertFalse(newCatalogue.sources[0].mayBeAnalysed)
        XCTAssertFalse(newCatalogue.sources[0].terms.automatedUseAllowed)
        XCTAssertEqual(newCatalogue.sources[0].terms.termsURL, URL(string: "https://example.com/terms")!)
        XCTAssertEqual(newCatalogue.sources[0].terms.termsReadOn, Date(timeIntervalSince1970: 2_000_000_000))
    }

    func testRevokingConfirmationForSourceIDUnknownReturnsSame() {
        let catalogue = makeCatalogue(sources: [makeSource(host: "cctv.austinmobility.io")])

        let newCatalogue = catalogue.revokingConfirmation(forSourceID: UUID())

        // Should be unchanged
        XCTAssertEqual(newCatalogue.sources.count, catalogue.sources.count)
    }

    // MARK: - mayBeAnalysed integration

    func testConfirmedSourceSatisfiesMayBeAnalysed() {
        let id = UUID()
        let source = makeSource(id: id, host: "cctv.austinmobility.io")
        let catalogue = makeCatalogue(sources: [source])

        let termsURL = URL(string: "https://example.com/terms")!
        let newCatalogue = try! catalogue.confirmingTerms(
            forHost: "cctv.austinmobility.io",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "Test"
        )

        XCTAssertTrue(newCatalogue.sources[0].mayBeAnalysed)
    }

    func testRevokedSourceFailsMayBeAnalysedButKeepsTermsURL() {
        let id = UUID()
        let confirmedTerms = FeedTerms(
            licenseClass: .publicDomain,
            termsURL: URL(string: "https://example.com/terms")!,
            termsReadOn: Date(),
            attribution: "Test",
            automatedUseAllowed: true
        )
        let catalogue = makeCatalogue(sources: [makeSource(id: id, host: "cctv.austinmobility.io", terms: confirmedTerms)])

        let newCatalogue = catalogue.revokingConfirmation(forSourceID: id)

        XCTAssertFalse(newCatalogue.sources[0].mayBeAnalysed)
        XCTAssertEqual(newCatalogue.sources[0].terms.termsURL, URL(string: "https://example.com/terms")!)
        XCTAssertEqual(newCatalogue.sources[0].terms.termsReadOn, confirmedTerms.termsReadOn)
    }

    // MARK: - Edge cases

    func testMultipleHostsUnchanged() {
        let id1 = UUID()
        let id2 = UUID()
        let sources = [
            makeSource(id: id1, host: "host1.example.com"),
            makeSource(id: id2, host: "host2.example.com"),
        ]
        let catalogue = makeCatalogue(sources: sources)

        let termsURL = URL(string: "https://example.com/terms")!
        let newCatalogue = try! catalogue.confirmingTerms(
            forHost: "host1.example.com",
            licenseClass: .publicDomain,
            termsURL: termsURL,
            attribution: "Test"
        )

        XCTAssertTrue(newCatalogue.sources[0].mayBeAnalysed)
        XCTAssertFalse(newCatalogue.sources[1].mayBeAnalysed)
    }

    func testValidLicenseClasses() {
        let id = UUID()
        let catalogue = makeCatalogue(sources: [makeSource(id: id, host: "example.com")])

        let termsURL = URL(string: "https://example.com/terms")!

        // All these should work
        for licenseClass in [FeedTerms.LicenseClass.publicDomain, .openLicence, .keyed, .permissioned] {
            let newCatalogue = try! catalogue.confirmingTerms(
                forHost: "example.com",
                licenseClass: licenseClass,
                termsURL: termsURL,
                attribution: licenseClass == .openLicence || licenseClass == .permissioned ? "Required" : ""
            )
            XCTAssertTrue(newCatalogue.sources[0].mayBeAnalysed, "License class \(licenseClass) should work")
        }
    }

    func testSortedHosts() {
        let sources = [
            makeSource(host: "zebra.example.com"),
            makeSource(host: "alpha.example.com"),
            makeSource(host: "beta.example.com"),
        ]
        let catalogue = makeCatalogue(sources: sources)

        let summaries = catalogue.hosts()
        XCTAssertEqual(summaries.map(\.host), ["alpha.example.com", "beta.example.com", "zebra.example.com"])
    }
}