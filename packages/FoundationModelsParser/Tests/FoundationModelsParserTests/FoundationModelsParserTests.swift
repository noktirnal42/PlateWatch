import Testing
import Foundation
@testable import FoundationModelsParser
import PlateKit

struct FoundationModelsParserTests {
    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test func testFleetMarkingsParsedStruct() {
        let fm = ParsedFleetMarkings(
            agencyName: "Austin Police Department",
            unitNumber: "4421",
            serviceClass: "POLICE",
            ownershipLine: "CITY OF AUSTIN",
            confidence: 0.95
        )
        #expect(fm.agencyName == "Austin Police Department")
        #expect(fm.unitNumber == "4421")
        #expect(fm.serviceClass == "POLICE")
        #expect(fm.ownershipLine == "CITY OF AUSTIN")
        #expect(fm.confidence == 0.95)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test func testFleetMarkingsParsedStructOptional() {
        let fm = ParsedFleetMarkings(
            agencyName: nil,
            unitNumber: nil,
            serviceClass: nil,
            ownershipLine: nil,
            confidence: 0.1
        )
        #expect(fm.agencyName == nil)
        #expect(fm.unitNumber == nil)
        #expect(fm.serviceClass == nil)
        #expect(fm.ownershipLine == nil)
        #expect(fm.confidence == 0.1)
    }

    @available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
    @Test func testFleetMarkingsErrorDescription() {
        let err = FleetMarkingsError.appleIntelligenceUnavailable(.unavailable(.modelNotReady))
        // Error should have a meaningful description
        #expect(!err.localizedDescription.isEmpty)
    }
}