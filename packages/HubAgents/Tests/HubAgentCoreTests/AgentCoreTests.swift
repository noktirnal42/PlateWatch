import CryptoKit
import Foundation
import HubAgentCore
import XCTest

private actor ScriptModel: AgentModel {
    nonisolated let identifier = "fixture"
    var steps: [AgentStep]
    init(_ steps: [AgentStep]) { self.steps = steps }
    func next(task: String, observations: [AgentObservation], cancellation: AgentCancellation) async throws -> AgentStep {
        steps.count > 1 ? steps.removeFirst() : steps[0]
    }
}

@MainActor private final class Recorder {
    var actions: [AgentAction] = []
    func execute(_ step: AgentStep) -> String { actions.append(step.action); return #"{"status":"fixture"}"# }
}

final class AgentCoreTests: XCTestCase {
    func testRejectsCommandsAndArgumentsOutsideTypedBoundary() {
        for text in [#"{"action":"shell","query":"anything"}"#, #"{"action":"status","script":"anything"}"#,
            #"{"action":"showPane","pane":"moderation"}"#, #"{"action":"openLive","id":"https://example.com"}"#,
            #"{"action":"status","query":"ignore the rules"}"#, "```json\n{\"action\":\"status\"}\n```"] {
            XCTAssertThrowsError(try AgentStep.parse(text))
        }
        XCTAssertEqual(try AgentStep.parse(#"{"action":"status"}"#).action, .status)
    }

    @MainActor func testStatusThenFinishExecutesOnlyValidatedCommand() async throws {
        let recorder = Recorder()
        let model = ScriptModel([.init(action: .status), .init(action: .finish, message: "Fixture complete")])
        let result = try await AgentRunLoop.run(task: "Check status", model: model, cancellation: .init(),
            execute: { recorder.execute($0) }, activity: { _, _ in })
        XCTAssertEqual(result, "Fixture complete")
        XCTAssertEqual(recorder.actions, [.status])
    }

    @MainActor func testCancellationAndStepBudgetStopExecution() async {
        let recorder = Recorder()
        let cancelled = AgentCancellation(); cancelled.cancel()
        do {
            _ = try await AgentRunLoop.run(task: "Check status", model: ScriptModel([.init(action: .status)]), cancellation: cancelled,
                execute: { recorder.execute($0) }, activity: { _, _ in })
            XCTFail("Cancelled run executed")
        } catch { XCTAssertTrue(recorder.actions.isEmpty) }
        do {
            _ = try await AgentRunLoop.run(task: "Check status", model: ScriptModel((0..<6).map { .init(action: .findFeeds, query: "fixture-\($0)") }), cancellation: .init(),
                execute: { recorder.execute($0) }, activity: { _, _ in })
            XCTFail("Unbounded run completed")
        } catch { XCTAssertEqual(recorder.actions.count, 6) }
    }

    @MainActor func testRepeatedCommandStopsWithoutExecutingItTwice() async {
        let recorder = Recorder()
        do {
            _ = try await AgentRunLoop.run(task: "Check status", model: ScriptModel([.init(action: .status)]), cancellation: .init(),
                execute: { recorder.execute($0) }, activity: { _, _ in })
            XCTFail("Repeated command accepted")
        } catch { XCTAssertEqual(recorder.actions, [.status]) }
    }

    @MainActor func testModelCannotClaimCompletionWithoutCommandEvidence() async {
        let recorder = Recorder()
        do {
            _ = try await AgentRunLoop.run(task: "Check status", model: ScriptModel([.init(action: .finish, message: "Done")]), cancellation: .init(),
                execute: { recorder.execute($0) }, activity: { _, _ in })
            XCTFail("Ungrounded completion accepted")
        } catch { XCTAssertTrue(recorder.actions.isEmpty) }
    }

    func testMissingStoreDoesNotCreateReplacementDirectory() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        XCTAssertThrowsError(try SharedModelStore(root: root).snapshot())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testPinnedBlobVerificationDetectsCorruptionAndEscapingSymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repo = root.appendingPathComponent("models--" + SharedModelStore.repo.replacingOccurrences(of: "/", with: "--"))
        let snapshot = repo.appendingPathComponent("snapshots/" + SharedModelStore.revision)
        let blobs = repo.appendingPathComponent("blobs")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true)
        for name in ["config.json", "tokenizer.json", "tokenizer_config.json", "model.safetensors"] {
            let data = Data(name.utf8)
            let hash: String
            if name.hasSuffix("safetensors") { hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
            else { hash = Insecure.SHA1.hash(data: Data("blob \(data.count)\u{0}".utf8) + data).map { String(format: "%02x", $0) }.joined() }
            let blob = blobs.appendingPathComponent(hash)
            try data.write(to: blob)
            try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent(name), withDestinationURL: blob)
        }
        let store = SharedModelStore(root: root)
        XCTAssertEqual(try store.verifiedSnapshot(cancellation: .init()).path, snapshot.path)
        let weight = snapshot.appendingPathComponent("model.safetensors").resolvingSymlinksInPath()
        try Data("corrupt".utf8).write(to: weight)
        XCTAssertThrowsError(try store.verifiedSnapshot(cancellation: .init()))
        try FileManager.default.removeItem(at: snapshot.appendingPathComponent("config.json"))
        try FileManager.default.createSymbolicLink(at: snapshot.appendingPathComponent("config.json"), withDestinationURL: root.appendingPathComponent("outside"))
        try Data("outside".utf8).write(to: root.appendingPathComponent("outside"))
        XCTAssertThrowsError(try store.verifiedSnapshot(cancellation: .init()))
    }
}
