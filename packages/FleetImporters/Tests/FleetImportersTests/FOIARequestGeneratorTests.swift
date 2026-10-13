import Foundation
import XCTest
@testable import FleetImporters

final class FOIARequestGeneratorTests: XCTestCase {

    private let target = FOIARequestGenerator.Target(
        agencyName: "City of Example Police Department",
        recordsOfficeURL: URL(string: "https://records.example.gov/request"),
        stateName: "Texas")

    func testDraftNamesAgencyAndSubject() {
        let draft = FOIARequestGenerator().draft(target: target,
                                                 requestDate: Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertTrue(draft.subject.contains("City of Example Police Department"))
        XCTAssertTrue(draft.body.contains("To the Public Records Officer, City of Example Police Department (Texas):"))
    }

    func testValidUnitsAreIncludedNormalisedAndDeduplicated() {
        let draft = FOIARequestGenerator().draft(target: target,
                                                 units: [" 4421 ", "a-12", "4421", "F/E-7"])
        XCTAssertEqual(draft.includedUnits, ["4421", "A-12", "F/E-7"])
        XCTAssertTrue(draft.rejectedUnits.isEmpty)
    }

    func testPersonalLookingUnitsAreRejected() {
        // Names, addresses, and free text must never reach the letter.
        let draft = FOIARequestGenerator().draft(target: target,
                                                 units: ["John Smith", "123 Main St", "4421", "ABC1234567890"])
        XCTAssertEqual(draft.includedUnits, ["4421"])
        XCTAssertEqual(draft.rejectedUnits, ["John Smith", "123 Main St", "ABC1234567890"])
        XCTAssertFalse(draft.body.contains("John Smith"))
        XCTAssertFalse(draft.body.contains("123 Main"))
    }

    func testNoEmployeeNamesAreRequested() {
        let draft = FOIARequestGenerator().draft(target: target, units: ["4421"])
        XCTAssertTrue(draft.body.contains("do not include names of employees"))
    }

    func testRequesterIsAPlaceholderNotAPersonalIdentity() {
        let draft = FOIARequestGenerator().draft(target: target)
        XCTAssertTrue(draft.body.contains("[Your name]"))
        XCTAssertTrue(draft.body.contains("[Mailing address or email for the response]"))
    }

    func testCustomRequesterPlaceholderIsUsed() {
        let draft = FOIARequestGenerator().draft(target: target, requesterPlaceholder: "Pat Doe")
        XCTAssertTrue(draft.body.contains("Sincerely,\nPat Doe"))
    }

    func testScopeControlsWhichItemsAppear() {
        let minimal = FOIARequestGenerator.Scope(fleetInventory: true, unitVehicleLinks: false,
                                                 alprPolicy: false, alprRetention: false,
                                                 alprVendorContracts: false)
        let draft = FOIARequestGenerator().draft(target: target, scope: minimal)
        XCTAssertTrue(draft.body.contains("1. A list of all motor vehicles"))
        XCTAssertFalse(draft.body.contains("retention schedule"))
        XCTAssertFalse(draft.body.contains("vendor that provides ALPR"))
        XCTAssertFalse(draft.body.contains("automated license plate reader"))
    }

    func testVendorContractsOnlyWhenRequested() {
        let off = FOIARequestGenerator().draft(target: target)
        XCTAssertFalse(off.body.contains("vendor that provides ALPR"))
        let on = FOIARequestGenerator().draft(
            target: target, scope: .init(alprVendorContracts: true))
        XCTAssertTrue(on.body.contains("vendor that provides ALPR"))
    }

    func testItemsAreNumberedSequentially() {
        let draft = FOIARequestGenerator().draft(
            target: target, scope: .init(alprVendorContracts: true))
        for n in 1...5 {
            XCTAssertTrue(draft.body.contains("\(n). "))
        }
        XCTAssertFalse(draft.body.contains("6. "))
    }

    func testPortalGuidanceIncludedWhenKnown() {
        let withPortal = FOIARequestGenerator().draft(target: target)
        XCTAssertTrue(withPortal.body.contains("https://records.example.gov/request"))
        let without = FOIARequestGenerator().draft(
            target: .init(agencyName: "Example Transit Authority"))
        XCTAssertTrue(without.body.contains("Please direct this request to your public records office."))
    }

    func testUnitValidationRules() {
        XCTAssertTrue(FOIARequestGenerator.isUnitIdentifier("4421"))
        XCTAssertTrue(FOIARequestGenerator.isUnitIdentifier("A-12/B"))
        XCTAssertFalse(FOIARequestGenerator.isUnitIdentifier(""))
        XCTAssertFalse(FOIARequestGenerator.isUnitIdentifier("ABCDEFGHIJKLM")) // 13 chars
        XCTAssertFalse(FOIARequestGenerator.isUnitIdentifier("UNIT 4"))       // space
        XCTAssertFalse(FOIARequestGenerator.isUnitIdentifier("é12"))          // non-ASCII
    }
}
