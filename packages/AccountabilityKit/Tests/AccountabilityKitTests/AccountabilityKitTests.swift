import XCTest
@testable import AccountabilityKit
import PlateKit

final class AccountabilityKitTests: XCTestCase {
    private let citation = SourceCitation(
        sourceType: .agencyRoster,
        url: URL(string: "https://example.gov/roster")!,
        retrievedAt: Date(timeIntervalSince1970: 1_760_000_000))

    func testProfileRequiresCitation() {
        XCTAssertThrowsError(try OfficialProfile(name: "J. Doe", citations: [])) {
            XCTAssertEqual($0 as? OfficialProfile.CreationError, .missingCitation)
        }
        XCTAssertThrowsError(try OfficialProfile(name: "  ", citations: [citation]))
        let p = try? OfficialProfile(name: "J. Doe", role: "Patrol Officer", citations: [citation])
        XCTAssertEqual(p?.name, "J. Doe")
    }

    func testIncidentRecordRequiresCitationAndReference() {
        XCTAssertThrowsError(try IncidentRecord(kind: .lawsuit, reference: "", citations: [citation]))
        XCTAssertThrowsError(try IncidentRecord(kind: .lawsuit, reference: "1:21-cv-00001", citations: []))
        let r = try? IncidentRecord(kind: .bradyList, reference: "Entry 42", status: "as released",
                                    citations: [SourceCitation(sourceType: .bradyList, retrievedAt: Date())])
        XCTAssertEqual(r?.kind, .bradyList)
    }

    func testPersonLinkPublishRules() throws {
        // Inference: labeled, never publishable.
        var link = try PersonLink(officialID: UUID(), unitNumber: "D756",
                                  confidence: 0.6, citations: [citation])
        XCTAssertFalse(link.canPublish)
        // Full confidence without moderator confirmation is rejected.
        XCTAssertThrowsError(try PersonLink(officialID: UUID(), unitNumber: "D756",
                                            confidence: 1.0, citations: [citation]))
        // Moderator confirmation without an external source is rejected.
        XCTAssertThrowsError(try PersonLink(officialID: UUID(), unitNumber: "D756",
                                            confidence: 0.6, isModeratorConfirmed: true,
                                            citations: [SourceCitation(sourceType: .communityVerified)]))
        // Confirmed with an external citation publishes; community-only
        // confirmation is rejected.
        XCTAssertThrowsError(try link.moderatorConfirm(
            additionalCitation: SourceCitation(sourceType: .communityVerified)))
        try link.moderatorConfirm(
            additionalCitation: SourceCitation(sourceType: .agencyRoster, retrievedAt: Date()))
        XCTAssertTrue(link.canPublish)
        XCTAssertEqual(link.confidence, 1.0)
        // Confidence claims beyond what evidence supports are rejected,
        // not clamped: certainty requires moderator confirmation.
        XCTAssertThrowsError(try PersonLink(officialID: UUID(), unitNumber: "X",
                                            confidence: 7, citations: [citation]))
        let under = try PersonLink(officialID: UUID(), unitNumber: "X",
                                   confidence: -2, citations: [citation])
        XCTAssertEqual(under.confidence, 0.0)
    }
}
