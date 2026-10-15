import AccountabilityKit
import Foundation
import PlateKit
import XCTest

final class CourtSearchTests: XCTestCase {
    private func candidate(_ reference: String) -> RecordCandidate {
        .init(kind: .lawsuit, reference: reference, releasedBy: "Test court", excerpt: reference,
              citation: .init(sourceType: .courtDocket))
    }

    @MainActor
    func testNewSearchReplacesResultsAndRepeatResolvesSavedIDs() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = RecordsWorkspace(directory: directory)
        let first = candidate("A"), second = candidate("B")
        _ = await workspace.runCourtSearch(query: "first", source: "Test") { [first] }
        _ = await workspace.runCourtSearch(query: "second", source: "Test") { [second] }
        XCTAssertEqual(workspace.currentCourtResults.map(\.reference), ["B"])
        XCTAssertEqual(workspace.ledger.pending.count, 2)
        // A repeated response has a fresh UUID but the same ledger key.
        let repeated = candidate("B")
        let added = await workspace.runCourtSearch(query: "second", source: "Test") { [repeated] }
        XCTAssertEqual(added, 0)
        XCTAssertEqual(workspace.currentCourtResults.map(\.id), [second.id])
        _ = await workspace.runCourtSearch(query: "empty", source: "Test") { [] }
        XCTAssertTrue(workspace.currentCourtResults.isEmpty)
        XCTAssertEqual(workspace.ledger.pending.count, 2)
    }

    @MainActor
    func testFailureClearsPreviousResultsWithoutDeletingAcceptedRecord() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = RecordsWorkspace(directory: directory)
        let first = candidate("A")
        _ = await workspace.runCourtSearch(query: "first", source: "Test") { [first] }
        try workspace.ledger.accept(candidateID: first.id, subject: nil, agencyID: nil)
        _ = await workspace.runCourtSearch(query: "failed", source: "Test") { throw URLError(.timedOut) }
        XCTAssertTrue(workspace.currentCourtResults.isEmpty)
        XCTAssertFalse(workspace.lastError.isEmpty)
        XCTAssertFalse(workspace.courtSearchRunning)
        XCTAssertEqual(workspace.ledger.incidents.count, 1)
    }

    @MainActor
    func testOlderCompletionCannotReplaceCurrentSearch() async {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let workspace = RecordsWorkspace(directory: directory)
        let older = candidate("old"), newer = candidate("new")
        var resume: CheckedContinuation<[RecordCandidate], Never>?
        let oldTask = Task { @MainActor in
            await workspace.runCourtSearch(query: "old", source: "Test") {
                await withCheckedContinuation { resume = $0 }
            }
        }
        while resume == nil { await Task.yield() }
        _ = await workspace.runCourtSearch(query: "new", source: "Test") { [newer] }
        resume?.resume(returning: [older])
        _ = await oldTask.value
        XCTAssertEqual(workspace.currentCourtQuery, "new")
        XCTAssertEqual(workspace.currentCourtResults.map(\.reference), ["new"])
        XCTAssertEqual(workspace.ledger.pending.count, 1)
    }
}
