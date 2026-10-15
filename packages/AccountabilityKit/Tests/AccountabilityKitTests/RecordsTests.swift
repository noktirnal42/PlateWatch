import XCTest
@testable import AccountabilityKit
import PlateKit

final class FOIATrackerTests: XCTestCase {
    private let cal = Calendar.gregorianUTC
    private func date(_ y: Int, _ m: Int, _ d: Int) -> Date { cal.date(from: DateComponents(year: y, month: m, day: d, hour: 12))! }

    func testBusinessDayDeadlineSkipsWeekends() {
        // Fri 2026-10-02 + 5 business days = Fri 2026-10-09; + 20 = Fri 2026-10-30.
        let rule5 = FOIADeadlines.Rule(days: 5, businessDays: true, covers: .response, citation: "", verified: false)
        XCTAssertEqual(FOIADeadlines.dueDate(from: date(2026, 10, 2), rule: rule5, calendar: cal), date(2026, 10, 9))
        let us = FOIADeadlines.rule(forState: "us")!
        XCTAssertEqual(FOIADeadlines.dueDate(from: date(2026, 10, 2), rule: us, calendar: cal), date(2026, 10, 30))
    }

    func testCalendarDayDeadlineAndUnknownState() {
        let ca = FOIADeadlines.rule(forState: "CA")!
        XCTAssertEqual(FOIADeadlines.dueDate(from: date(2026, 10, 2), rule: ca, calendar: cal), date(2026, 10, 12))
        XCTAssertNil(FOIADeadlines.rule(forState: "ZZ"))
        XCTAssertTrue(FOIADeadlines.rules.values.allSatisfy { !$0.verified }, "nothing is claimed verified yet")
    }

    func testLifecycleOverdueAndAppeal() throws {
        var r = FOIARequest(agencyName: "Example PD", stateCode: "il", subject: "Fleet inventory", body: "…")
        XCTAssertThrowsError(try r.transition(to: .acknowledged, on: date(2026, 10, 3))) {
            XCTAssertEqual($0 as? FOIARequest.TransitionError, .notYetSubmitted)
        }
        r.markSubmitted(on: date(2026, 10, 5))
        XCTAssertEqual(r.dueOn, date(2026, 10, 12))
        XCTAssertFalse(r.isOverdue(asOf: date(2026, 10, 12)))
        XCTAssertTrue(r.isOverdue(asOf: date(2026, 10, 13)))
        XCTAssertThrowsError(try r.transition(to: .appealed, on: date(2026, 10, 6)), "not overdue, not denied")
        try r.transition(to: .appealed, on: date(2026, 10, 14), note: "no response")      // overdue ⇒ allowed
        XCTAssertEqual(r.status, .appealed)
        try r.transition(to: .closed, on: date(2026, 10, 20))
        XCTAssertThrowsError(try r.transition(to: .fulfilled, on: date(2026, 10, 21)))
    }

    func testOverrideDueDateSurvivesSubmission() {
        var r = FOIARequest(agencyName: "A", stateCode: "TX", subject: "s", body: "b")
        r.setDueDate(date(2026, 12, 1))
        r.markSubmitted(on: date(2026, 10, 5))
        XCTAssertEqual(r.dueOn, date(2026, 12, 1))
    }

    func testReleaseIsCitedAndHashed() throws {
        var r = FOIARequest(agencyName: "A", subject: "s", body: "b")
        r.markSubmitted(on: date(2026, 10, 5))
        XCTAssertThrowsError(try r.addRelease(description: " ", fileName: nil, data: Data(), receivedOn: date(2026, 10, 6)))
        try r.addRelease(description: "Fleet list PDF", fileName: "fleet.pdf", data: Data("abc".utf8), receivedOn: date(2026, 10, 6))
        let c = r.releases[0].citation
        XCTAssertEqual(c.sourceType, .foiaRelease)
        XCTAssertEqual(c.excerptHashSHA256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    func testAppealDraftNamesDenialWithoutLegalClaims() throws {
        var r = FOIARequest(agencyName: "Example PD", stateCode: "MA", subject: "Fleet inventory", body: "…")
        r.markSubmitted(on: date(2026, 10, 5))
        try r.transition(to: .denied, on: date(2026, 10, 20), note: "exempt")
        let d = r.appealDraft(asOf: date(2026, 10, 21))
        XCTAssertTrue(d.body.contains("was denied"))
        XCTAssertTrue(d.body.contains("[Requester name]"))
        XCTAssertTrue(d.subject.contains("Fleet inventory"))
    }

    func testTrackerPersistsAndFlagsOverdue() throws {
        var t = FOIATracker()
        var a = FOIARequest(agencyName: "A", stateCode: "IL", subject: "s", body: "b"); a.markSubmitted(on: date(2026, 10, 5))
        let b = FOIARequest(agencyName: "B", subject: "s", body: "b")
        t.upsert(a); t.upsert(b)
        XCTAssertEqual(t.overdue(asOf: date(2026, 11, 1)).map(\.agencyName), ["A"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("foia-\(UUID().uuidString).json")
        let store = JSONFileStore<FOIATracker>(url: url)
        try store.save(t)
        XCTAssertEqual(store.load(default: FOIATracker()), t)
        try? FileManager.default.removeItem(at: url)
    }
}

final class RecordImportTests: XCTestCase {
    private let source = PublishedListImporter.Source(kind: .bradyList, title: "Example County DA list", releasedBy: "Example County DA",
                                                      url: URL(string: "https://da.example.gov/brady.csv"),
                                                      retrievedAt: Date(timeIntervalSince1970: 1_760_000_000))
    private let csv = "Name,Agency,Entry,Status,Date\r\n\"Doe, Jane\",Example PD,B-17,\"sustained, \"\"untruthfulness\"\"\",2024-03-01\n,,,,\nRoe Richard,Other PD,,,\n"

    func testCSVParsingHandlesQuotesAndBlankRows() throws {
        let rows = PublishedListImporter.parseCSV(csv)
        XCTAssertEqual(rows[1][0], "Doe, Jane")
        XCTAssertEqual(rows[1][3], "sustained, \"untruthfulness\"")
        let c = try PublishedListImporter().candidates(fromCSV: csv, source: source,
            columns: .init(name: "name", agency: "agency", reference: "entry", status: "status", date: "date"))
        XCTAssertEqual(c.count, 2, "blank row skipped")
        XCTAssertEqual(c[0].subjectName, "Doe, Jane")
        XCTAssertEqual(c[0].status, "sustained, \"untruthfulness\"", "status verbatim")
        XCTAssertEqual(c[0].reference, "B-17")
        XCTAssertEqual(c[0].releasedBy, "Example County DA")
        XCTAssertEqual(c[0].citation.sourceType, .bradyList)
        XCTAssertNotNil(c[0].citation.excerptHashSHA256)
        XCTAssertNotNil(c[0].filedOn)
        XCTAssertEqual(c[1].reference, "Example County DA list, row 3", "no reference column value ⇒ a locator, not an invented ID")
        XCTAssertEqual(c.map(\.review), [.pending, .pending])
    }

    func testImporterRejectsWrongKindAndMissingColumn() {
        XCTAssertThrowsError(try PublishedListImporter().candidates(fromCSV: csv,
            source: .init(kind: .news, title: "t", releasedBy: "x"), columns: .init(name: "name")))
        XCTAssertThrowsError(try PublishedListImporter().candidates(fromCSV: csv, source: source, columns: .init(name: "surname"))) {
            XCTAssertEqual($0 as? PublishedListImporter.ImportError, .missingColumn("surname"))
        }
        XCTAssertThrowsError(try PublishedListImporter().candidates(fromCSV: "Name\n", source: source, columns: .init(name: "name")))
    }

    func testAcceptingMakesACitedRecordOnlyOnce() throws {
        var ledger = RecordsLedger()
        let c = try PublishedListImporter().candidates(fromCSV: csv, source: source, columns: .init(name: "name", reference: "entry"))
        XCTAssertEqual(ledger.add(c), 2)
        XCTAssertEqual(ledger.add(c), 0, "re-import is idempotent")
        try ledger.accept(candidateID: c[0].id, subject: nil, agencyID: nil)
        XCTAssertEqual(ledger.incidents.count, 1)
        XCTAssertEqual(ledger.pending.count, 1)
        XCTAssertThrowsError(try ledger.accept(candidateID: c[0].id, subject: nil, agencyID: nil))
        var comm = RecordCandidate(kind: .news, reference: "r", releasedBy: "x", excerpt: "e", citation: SourceCitation(sourceType: .communityVerified))
        XCTAssertThrowsError(try comm.accept(subject: nil, agencyID: nil))
    }

    func testNameAloneNeverConfirmsAPerson() throws {
        let cite = SourceCitation(sourceType: .agencyRoster, retrievedAt: Date())
        let agency = UUID()
        let jane = try OfficialProfile(name: "Jane Doe", agencyID: agency, citations: [cite])
        let other = try OfficialProfile(name: "Jane Doe", citations: [cite])
        let jan = try OfficialProfile(name: "Janet Doe", citations: [cite])
        let nobody = try OfficialProfile(name: "Sam Smith", citations: [cite])
        let cand = RecordCandidate(kind: .bradyList, reference: "B-1", subjectName: "DOE, Jane", releasedBy: "DA", excerpt: "e", citation: cite)
        XCTAssertTrue(PersonMatcher.suggest(for: cand, among: [nobody]).isEmpty)
        let s = PersonMatcher.suggest(for: RecordCandidate(kind: .bradyList, reference: "B-1", subjectName: "Jane Doe", releasedBy: "DA", excerpt: "e", citation: cite),
                                      among: [jane, other, jan, nobody], agencyID: agency)
        XCTAssertTrue(s.allSatisfy { $0.confidence < 1 })
        XCTAssertEqual(s.first?.profile.id, jane.id, "same name + same agency ranks first")
        XCTAssertFalse(s.contains { $0.profile.id == nobody.id })
    }
}

private struct FakeFetcher: HTTPFetching {
    var responses: [String: (Data, Int)]
    func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int) {
        // Foundation's URL.path may or may not keep a trailing slash; match on the slash-trimmed host+path.
        func trimmed(_ s: String) -> String { s.hasSuffix("/") ? String(s.dropLast()) : s }
        let key = trimmed(request.url!.host! + request.url!.path)
        guard let r = responses.first(where: { trimmed($0.key) == key })?.value else { return (Data(), 404) }
        return r
    }
}

final class CourtTests: XCTestCase {
    func testCourtListenerParsesAndMakesPendingCandidates() async throws {
        let json = #"{"results":[{"caseName":"Roe v. Town of X","docketNumber":"1:24-cv-00012","court":"D. Mass.","dateFiled":"2024-02-01","dateTerminated":"2025-06-30T00:00:00Z","docket_absolute_url":"/docket/1/roe-v-x/"},{"caseName":"no number"}]}"#
        let client = CourtListenerClient(fetcher: FakeFetcher(responses: ["www.courtlistener.com/api/rest/v4/search/": (Data(json.utf8), 200)]), token: "t")
        let dockets = try await client.search(query: "\"Town of X\" police")
        XCTAssertEqual(dockets.count, 1)
        XCTAssertEqual(dockets[0].url?.absoluteString, "https://www.courtlistener.com/docket/1/roe-v-x/")
        let c = dockets[0].candidate(retrievedAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(c.status, "terminated 2025-06-30")
        XCTAssertEqual(c.kind, .lawsuit)
        XCTAssertEqual(c.citation.sourceType, .courtDocket)
        XCTAssertEqual(c.review, .pending)
        XCTAssertEqual(client.request(query: "q").value(forHTTPHeaderField: "Authorization"), "Token t")
        XCTAssertTrue(client.request(query: "q").url!.absoluteString.hasPrefix("https://www.courtlistener.com/api/rest/v4/search/?"), "the API needs the trailing slash")
    }

    func testCourtListenerErrors() async {
        let bad = CourtListenerClient(fetcher: FakeFetcher(responses: [:]))
        do { _ = try await bad.search(query: "x"); XCTFail() } catch { XCTAssertEqual(error as? CourtClientError, .http(404)) }
        XCTAssertThrowsError(try CourtListenerClient.parse(Data("[]".utf8)))
    }

    private let day = Date(timeIntervalSince1970: 1_791_000_000)   // 2026-Q4

    func testPacerStaysFreeThenRefusesUnlessTheLimitIsRaised() {
        var b = PacerBudget()
        XCTAssertEqual(b.estimate(pages: 100, isDocument: true), 3, "per-document cap")
        XCTAssertEqual(b.check(estimatedCost: 29, on: day), .allowedFree)
        b.record(actualCost: 29, on: day)
        XCTAssertEqual(b.remainingFree(on: day), 1)
        XCTAssertEqual(b.check(estimatedCost: 1, on: day), .allowedFree, "exactly at the allowance is still free")
        guard case .denied = b.check(estimatedCost: Decimal(string: "1.10")!, on: day) else { return XCTFail("default limit is $0") }
        b.extraLimitUSD = 5
        XCTAssertEqual(b.check(estimatedCost: Decimal(string: "1.10")!, on: day), .allowedPaid(billableUSD: Decimal(string: "0.10")!))
        b.record(actualCost: 6, on: day)                                  // 35 spent: $5 over
        XCTAssertEqual(b.remainingExtra(on: day), 0)
        guard case .denied = b.check(estimatedCost: Decimal(string: "0.10")!, on: day) else { return XCTFail("limit reached") }
    }

    func testPacerQuarterRollsOver() {
        var b = PacerBudget()
        b.record(actualCost: 30, on: day)
        let nextQuarter = day.addingTimeInterval(100 * 86_400)
        XCTAssertNotEqual(PacerBudget.quarterKey(for: day), PacerBudget.quarterKey(for: nextQuarter))
        XCTAssertEqual(b.check(estimatedCost: 5, on: nextQuarter), .allowedFree)
    }

    func testPacerDeniedBudgetMakesNoNetworkCall() async {
        struct Boom: HTTPFetching { func fetch(_ r: URLRequest) async throws -> (data: Data, status: Int) { XCTFail("network used"); return (Data(), 500) } }
        var b = PacerBudget(); b.record(actualCost: 30, on: Date())
        var client = PacerClient(budget: b, fetcher: Boom())
        do { _ = try await client.findCases(partyName: "x", loginID: "u", password: "p"); XCTFail() }
        catch { guard case PacerClient.Failure.budgetDenied = error else { return XCTFail("\(error)") } }
    }

    func testPacerSuccessRecordsCostAndParses() async throws {
        let auth = #"{"nextGenCSO":"tok"}"#
        let cases = #"{"content":[{"caseTitle":"A v. B","caseNumberFull":"1:25-cv-00001","courtId":"mad","dateFiled":"2025-01-02"}]}"#
        let f = FakeFetcher(responses: ["pacer.login.uscourts.gov/services/cso-auth": (Data(auth.utf8), 200),
                                        "pcl.uscourts.gov/pcl-public-api/rest/cases/find": (Data(cases.utf8), 200)])
        var client = PacerClient(fetcher: f)
        let result = try await client.findCases(partyName: "B", loginID: "u", password: "p", now: day)
        XCTAssertEqual(result.map(\.docketNumber), ["1:25-cv-00001"])
        XCTAssertEqual(client.budget.spent(in: day), Decimal(string: "0.10")!)
        let reject = #"{"nextGenCSO":"","loginResult":"13","errorDescription":"Invalid username, password, or client code"}"#
        var bad = PacerClient(fetcher: FakeFetcher(responses: ["pacer.login.uscourts.gov/services/cso-auth": (Data(reject.utf8), 200)]))
        do { _ = try await bad.findCases(partyName: "B", loginID: "u", password: "hunter2"); XCTFail() } catch {
            guard case PacerClient.Failure.authFailed(let why) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(why.contains("loginResult 13") && why.contains("Invalid username"), "PACER's reason is surfaced: \(why)")
            XCTAssertFalse(why.contains("hunter2"), "the password never appears in an error")
        }
        XCTAssertEqual(bad.budget.spent(in: day), 0, "failed auth costs nothing")
    }
}

final class UnitRecordsIndexTests: XCTestCase {
    func testOnlyConfirmedLinksAndCitedRecordsAppearAndNoLocationExists() throws {
        let cite = SourceCitation(sourceType: .agencyRoster, retrievedAt: Date())
        let agency = UUID()
        let officer = try OfficialProfile(name: "Jane Doe", agencyID: agency, citations: [cite])
        var confirmed = try PersonLink(officialID: officer.id, unitNumber: "D-756", agencyKey: "example-pd", confidence: 0.6, citations: [cite])
        try confirmed.moderatorConfirm(additionalCitation: SourceCitation(sourceType: .foiaRelease, retrievedAt: Date()))
        let inferred = try PersonLink(officialID: officer.id, unitNumber: "D-999", agencyKey: "example-pd", confidence: 0.7, citations: [cite])
        let personal = try IncidentRecord(kind: .decertification, reference: "R-1", status: "decertified", subjectID: officer.id,
                                          agencyID: agency, agencyKey: "example-pd", citations: [SourceCitation(sourceType: .decertificationRegister, retrievedAt: Date())])
        let agencyLevel = try IncidentRecord(kind: .officialReport, reference: "Audit 2025-3", agencyID: agency, agencyKey: "example-pd",
                                             citations: [SourceCitation(sourceType: .openDataPortal, retrievedAt: Date())])
        let index = UnitRecordsIndex(ledger: RecordsLedger(incidents: [personal, agencyLevel], profiles: [officer], links: [confirmed, inferred]))

        let hit = index.records(forUnit: "d756", agencyKey: "Example-PD")
        XCTAssertEqual(hit.officials.map(\.profile.name), ["Jane Doe"])
        XCTAssertEqual(hit.officials[0].records.map(\.reference), ["R-1"])
        XCTAssertEqual(hit.agencyRecords.map(\.reference), ["Audit 2025-3"], "person-linked records are not duplicated as agency records")
        XCTAssertTrue(index.records(forUnit: "D999", agencyKey: "example-pd").officials.isEmpty, "inferred link never surfaces")
        XCTAssertTrue(index.records(forUnit: "D756", agencyKey: "other-pd").isEmpty, "same unit number, different agency")
        XCTAssertTrue(index.records(forUnit: "D756", agencyKey: nil).isEmpty, "no recognised agency ⇒ nothing shown")
        XCTAssertTrue(index.records(forUnit: "", agencyKey: "example-pd").officials.isEmpty)
    }
}

final class PeopleFlowTests: XCTestCase {
    private let roster = SourceCitation(sourceType: .agencyRoster, url: URL(string: "https://pd.example.gov/roster"), retrievedAt: Date())
    private let foia = SourceCitation(sourceType: .foiaRelease, retrievedAt: Date())

    func testProfileLinkConfirmAttachAndTakedown() throws {
        var ledger = RecordsLedger()
        XCTAssertThrowsError(try ledger.addProfile(name: "Jane Doe", role: "Officer",
                                                   citation: SourceCitation(sourceType: .communityVerified)))
        let jane = try ledger.addProfile(name: "Jane Doe", role: "Officer", citation: roster)
        let link = try ledger.proposeLink(profileID: jane.id, unitNumber: "D756", agencyKey: "example-pd", confidence: 1, citation: roster)
        XCTAssertLessThan(link.confidence, 1, "a proposal can never claim certainty")
        let rec = try IncidentRecord(kind: .decertification, reference: "R-1", agencyKey: "example-pd",
                                     citations: [SourceCitation(sourceType: .decertificationRegister, retrievedAt: Date())])
        ledger.incidents.append(rec)

        XCTAssertTrue(UnitRecordsIndex(ledger: ledger).records(forUnit: "D756", agencyKey: "example-pd").officials.isEmpty, "unconfirmed ⇒ hidden")
        XCTAssertThrowsError(try ledger.confirmLink(id: link.id, citation: SourceCitation(sourceType: .communityVerified)))
        try ledger.confirmLink(id: link.id, citation: foia)
        try ledger.attach(incidentID: rec.id, to: jane.id)
        let shown = UnitRecordsIndex(ledger: ledger).records(forUnit: "D756", agencyKey: "example-pd")
        XCTAssertEqual(shown.officials.first?.records.map(\.reference), ["R-1"])
        XCTAssertThrowsError(try ledger.attach(incidentID: rec.id, to: UUID()))
        XCTAssertThrowsError(try ledger.proposeLink(profileID: UUID(), unitNumber: "X", agencyKey: "a", citation: roster))

        ledger.removeProfile(id: jane.id)
        XCTAssertTrue(ledger.profiles.isEmpty && ledger.links.isEmpty)
        XCTAssertNil(ledger.incidents[0].subjectID, "the record detaches, it is not deleted")
        XCTAssertEqual(ledger.incidents.count, 1)
    }
}

final class RosterImportTests: XCTestCase {
    private let csv = "Name,Rank,Unit,Home Address,Phone,DOB\nJane Doe,Officer,D756,12 Elm St,555-0100,1980-01-01\nRichard Roe,Sergeant,,9 Oak Ave,555-0101,1975-05-05\n,Officer,D1,x,y,z\n"
    private let source = RosterImporter.Source(title: "Example PD roster", agencyName: "Example PD", agencyKey: "example-pd",
                                               releasedBy: "Example PD", url: URL(string: "https://pd.example.gov/roster"))

    func testOnlyMappedColumnsAreReadAndNothingPersonalIsKept() throws {
        let c = try RosterImporter().candidates(fromCSV: csv, source: source, columns: .init(name: "name", role: "rank", unit: "unit"))
        XCTAssertEqual(c.count, 2, "row without a name skipped")
        XCTAssertEqual(c[0].excerpt, "Name: Jane Doe; Role: Officer; Unit: D756")
        let encoded = String(data: try JSONEncoder().encode(c), encoding: .utf8)!
        for secret in ["Elm St", "555-0100", "1980-01-01", "Oak Ave"] { XCTAssertFalse(encoded.contains(secret), secret) }
        XCTAssertEqual(c[1].unitNumber, nil)
        XCTAssertEqual(c[0].citation.sourceType, .agencyRoster)
        XCTAssertTrue(c.allSatisfy { $0.review == .pending })
    }

    func testRejectsBadInputs() {
        XCTAssertThrowsError(try RosterImporter().candidates(fromCSV: csv, source: source, columns: .init(name: "officer")))
        XCTAssertThrowsError(try RosterImporter().candidates(fromCSV: "Name\n", source: source, columns: .init(name: "name")))
        var bad = source; bad.sourceType = .communityVerified
        XCTAssertThrowsError(try RosterImporter().candidates(fromCSV: csv, source: bad, columns: .init(name: "name")))
    }

    func testAcceptMakesProfileAndHiddenLinkAndIsIdempotent() throws {
        var ledger = RecordsLedger()
        let c = try RosterImporter().candidates(fromCSV: csv, source: source, columns: .init(name: "name", role: "rank", unit: "unit"))
        XCTAssertEqual(ledger.addRoster(c), 2)
        XCTAssertEqual(ledger.addRoster(c), 0, "re-import skipped")
        let jane = try ledger.acceptRoster(candidateID: c[0].id)
        XCTAssertEqual(ledger.profiles.count, 1)
        XCTAssertEqual(ledger.links.count, 1)
        XCTAssertFalse(ledger.links[0].canPublish, "a roster row only proposes the link")
        XCTAssertLessThan(ledger.links[0].confidence, 1)
        XCTAssertTrue(UnitRecordsIndex(ledger: ledger).records(forUnit: "D756", agencyKey: "example-pd").officials.isEmpty)
        XCTAssertThrowsError(try ledger.acceptRoster(candidateID: c[0].id), "already reviewed")
        _ = try ledger.acceptRoster(candidateID: c[1].id)
        XCTAssertEqual(ledger.profiles.count, 2)
        XCTAssertEqual(ledger.links.count, 1, "no unit ⇒ no link")
        XCTAssertEqual(ledger.pendingRoster.count, 0)
        // Same person from the same source again (new import run) reuses the profile.
        let again = try RosterImporter().candidates(fromCSV: csv + "Jane Doe,Officer,D800,x,y,z\n", source: source, columns: .init(name: "name", role: "rank", unit: "unit"))
        ledger.addRoster(again)
        let janeAgain = try ledger.acceptRoster(candidateID: ledger.pendingRoster[0].id)
        XCTAssertEqual(janeAgain.id, jane.id)
        XCTAssertEqual(ledger.profiles.count, 2)
    }

    func testOlderLedgerFilesStillDecode() throws {
        let old = #"{"candidates":[],"incidents":[],"profiles":[],"links":[]}"#
        let l = try JSONDecoder().decode(RecordsLedger.self, from: Data(old.utf8))
        XCTAssertTrue(l.rosterCandidates.isEmpty)
    }
}

final class PacerAuthRequestTests: XCTestCase {
    private final class Capture: HTTPFetching, @unchecked Sendable {
        var last: URLRequest?
        func fetch(_ request: URLRequest) async throws -> (data: Data, status: Int) {
            last = request
            return (Data(#"{"nextGenCSO":"tok","loginResult":"0","errorDescription":""}"#.utf8), 200)
        }
    }

    func testAuthSendsRedactFlagAndSanitisedClientCode() async throws {
        let cap = Capture()
        let client = PacerClient(fetcher: cap)
        let token = try await client.authenticate(loginID: "u", password: "p", clientCode: "my project, 1")
        XCTAssertEqual(token, "tok")
        let body = try JSONSerialization.jsonObject(with: cap.last!.httpBody!) as! [String: String]
        XCTAssertEqual(body["redactFlag"], "1", "PACER requires the redaction flag")
        XCTAssertEqual(body["clientCode"], "my-project--1", "no spaces or commas in client codes")
        XCTAssertEqual(cap.last?.value(forHTTPHeaderField: "Accept"), "application/json")
        _ = try await client.authenticate(loginID: "u", password: "p", clientCode: nil)
        XCTAssertNil((try JSONSerialization.jsonObject(with: cap.last!.httpBody!) as! [String: String])["clientCode"])
    }
}
