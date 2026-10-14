import XCTest
@testable import App
import XCTVapor
import Vapor

func withApp(_ body: (Application) async throws -> Void) async throws {
    let app = try await Application.make(.testing)
    do {
        try await body(app)
    } catch {
        try? await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
}

final class ModeratorTokenTests: XCTestCase {
    func testShortTokenDisablesConsole() async throws {
        try await withApp { app in
            try app.register(collection: ModeratorController(token: "too-short"))
            let res = try await app.sendRequest(.GET, "moderator")
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testMissingTokenDisablesConsole() async throws {
        try await withApp { app in
            try app.register(collection: ModeratorController(token: nil))
            let res = try await app.sendRequest(.GET, "moderator")
            XCTAssertEqual(res.status, .notFound)
        }
    }

    func testMissingCredentialsAreUnauthorizedWithChallenge() async throws {
        try await withApp { app in
            try app.register(collection: ModeratorController(token: String(repeating: "x", count: 32)))
            let res = try await app.sendRequest(.GET, "moderator")
            XCTAssertEqual(res.status, .unauthorized)
            XCTAssertNotNil(res.headers.first(name: "WWW-Authenticate"))
        }
    }

    func testWrongPasswordIsUnauthorized() async throws {
        try await withApp { app in
            try app.register(collection: ModeratorController(token: String(repeating: "x", count: 32)))
            let basic = "Basic " + Data("moderator:\(String(repeating: "y", count: 32))".utf8).base64EncodedString()
            let res = try await app.sendRequest(.GET, "moderator", headers: ["Authorization": basic])
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testTokenOneCharacterUnderMinimumDisablesConsole() async throws {
        try await withApp { app in
            let under = String(repeating: "a", count: ModeratorController.minimumTokenLength - 1)
            try app.register(collection: ModeratorController(token: under))
            let res = try await app.sendRequest(.GET, "moderator")
            XCTAssertEqual(res.status, .notFound)
        }
    }
}

final class ModeratorCSRFTests: XCTestCase {
    private let id = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private let token = String(repeating: "t", count: 32)

    func testCSRFIsDeterministicPerActionAndSighting() {
        let approve = ModeratorController.csrf(token: token, id: id, decision: "approve")
        XCTAssertEqual(approve, ModeratorController.csrf(token: token, id: id, decision: "approve"))
        XCTAssertNotEqual(approve, ModeratorController.csrf(token: token, id: id, decision: "reject"))
        XCTAssertNotEqual(approve, ModeratorController.csrf(token: token, id: UUID(), decision: "approve"))
    }

    func testCSRFDependsOnToken() {
        let a = ModeratorController.csrf(token: token, id: id, decision: "approve")
        let b = ModeratorController.csrf(token: String(repeating: "u", count: 32), id: id, decision: "approve")
        XCTAssertNotEqual(a, b)
    }

    func testCSRFIsHexSHA256Length() {
        XCTAssertEqual(ModeratorController.csrf(token: token, id: id, decision: "approve").count, 64)
    }

    func testConstantTimeEquals() {
        XCTAssertTrue(ModeratorController.constantTimeEquals("abc", "abc"))
        XCTAssertFalse(ModeratorController.constantTimeEquals("abc", "abd"))
        XCTAssertFalse(ModeratorController.constantTimeEquals("abc", "abcd"))
        XCTAssertFalse(ModeratorController.constantTimeEquals("", "x"))
        XCTAssertTrue(ModeratorController.constantTimeEquals("", ""))
    }

    func testEscapeNeutralisesMarkup() {
        let escaped = ModeratorController.escape(#"<script>alert("x") & 'y'</script>"#)
        XCTAssertFalse(escaped.contains("<script>"))
        XCTAssertFalse(escaped.contains("\""))
        XCTAssertTrue(escaped.contains("&lt;script&gt;"))
        XCTAssertTrue(escaped.contains("&quot;x&quot;"))
        XCTAssertTrue(escaped.contains("&#39;y&#39;"))
    }
}

final class PlatePersistenceTests: XCTestCase {
    /// LEGAL-ETHICS Rule 1: the plate is only a stored fact for
    /// fleet-confirmed sightings. The gate outcome drives that decision.
    func testOnlyFleetConfirmedMayCarryAPlate() {
        XCTAssertEqual(RedactionGateService.ModerationState.fleetConfirmed.rawValue, "fleetConfirmed")
        let fleet = SightingSubmissionDTO.sample(confidence: 0.9, unit: "4421")
        XCTAssertEqual(RedactionGateService.evaluate(fleet).state, .fleetConfirmed)
        let unknown = SightingSubmissionDTO.sample(confidence: 0.6, unit: nil)
        XCTAssertEqual(RedactionGateService.evaluate(unknown).state, .pending)
    }
}

private extension SightingSubmissionDTO {
    static func sample(confidence: Double, unit: String?) -> SightingSubmissionDTO {
        let json = """
        {"capturedAt":"2026-10-09T04:00:00Z","geohash6":"9v6kpv",
         "deviceIDHash":"dev-test","fleetConfidence":\(confidence),
         "plate":{"text":"1ABC234","issuingRegion":"US-CA","country":"US","plateDesign":null,"confidence":0.9},
         "vehicle":{"vehicleClass":"patrol","classConfidence":0.8},
         "markings":\(unit.map { #"{"agencyText":"AUSTIN POLICE","unitNumber":"\#($0)"}"# } ?? "null")}
        """
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        // swiftlint:disable:next force_try
        return try! decoder.decode(SightingSubmissionDTO.self, from: Data(json.utf8))
    }
}

final class ModeratorAPIAuthTests: XCTestCase {
    private let token = String(repeating: "x", count: 32)
    private var basic: String { "Basic " + Data("moderator:\(token)".utf8).base64EncodedString() }

    func testAPIRequiresCustomHeaderEvenWithValidCredentials() async throws {
        try await withApp { app in
            try app.register(collection: ModeratorController(token: token))
            let res = try await app.sendRequest(.GET, "moderator/api/queue", headers: ["Authorization": basic])
            XCTAssertEqual(res.status, .forbidden, "a cross-site request cannot add the header")
        }
    }

    func testAPIRejectsWrongPasswordWithHeader() async throws {
        try await withApp { app in
            try app.register(collection: ModeratorController(token: token))
            let bad = "Basic " + Data("moderator:nope".utf8).base64EncodedString()
            let res = try await app.sendRequest(.GET, "moderator/api/queue",
                                                headers: ["Authorization": bad, ModeratorController.apiHeader: "1"])
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testAPIDisabledWithoutToken() async throws {
        try await withApp { app in
            try app.register(collection: ModeratorController(token: nil))
            let res = try await app.sendRequest(.GET, "moderator/api/queue", headers: [ModeratorController.apiHeader: "1"])
            XCTAssertEqual(res.status, .notFound)
        }
    }
}
