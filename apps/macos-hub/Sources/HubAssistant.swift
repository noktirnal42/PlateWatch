import Foundation
import PlateSync
import HubAgentCore
import HubAgentProviders

@MainActor
final class HubAssistant: ObservableObject {
    enum Provider: String, CaseIterable, Identifiable {
        case mlx = "Local MLX", apple = "Apple Intelligence"
        var id: String { rawValue }
    }
    struct Activity: Identifiable {
        let id = UUID()
        let action: AgentAction
        var state: String
        var result = ""
    }
    struct JournalEntry: Codable, Identifiable {
        let id: UUID
        let date: Date
        let provider: String
        let outcome: String
        let actions: [String]
    }
    @Published private(set) var running = false
    @Published private(set) var status = "Ready"
    @Published private(set) var summary = ""
    @Published private(set) var activities: [Activity] = []
    @Published private(set) var history: [JournalEntry] = []
    @Published private(set) var journalError: String?
    private let mlx = MLXAgentModel()
    private var cancellation: AgentCancellation?
    private var run: Task<Void, Never>?

    init() {
        if let data = try? Data(contentsOf: Self.journalURL), data.count <= 200_000,
           let records = try? JSONDecoder.withISODates.decode([JournalEntry].self, from: data) { history = Array(records.suffix(100)) }
    }

    func availability(_ provider: Provider) -> String {
        switch provider {
        case .apple: return AppleAgentModel.availability ?? "On-device model available"
        case .mlx:
            #if !arch(arm64)
            return "MLX requires an Apple-silicon Mac."
            #else
            do { _ = try SharedModelStore().snapshot(); return "Pinned Qwen 1.5B is cached · verifies and loads on first run" }
            catch { return error.localizedDescription }
            #endif
        }
    }

    func start(task: String, provider: Provider, bridge: HubAgentBridge?) {
        guard !running, let bridge else { return }
        let cancellation = AgentCancellation(seconds: 90)
        self.cancellation = cancellation
        running = true; status = "Planning locally…"; summary = ""; activities = []
        let model: any AgentModel = provider == .mlx ? mlx : AppleAgentModel()
        run = Task { [weak self] in
            guard let self else { return }
            let outcome: String
            do {
                summary = try await AgentRunLoop.run(task: task, model: model, cancellation: cancellation,
                    execute: { [weak self] step in
                        let result = try Self.execute(step, bridge: bridge)
                        if let index = self?.activities.lastIndex(where: { $0.action == step.action && $0.state == "Running" }) {
                            self?.activities[index].result = result
                        }
                        return result
                    }, activity: { [weak self] action, state in
                        guard let self else { return }
                        if state == "Running" { activities.append(.init(action: action, state: state)) }
                        else if let index = activities.lastIndex(where: { $0.action == action && $0.state == "Running" }) { activities[index].state = state }
                        status = state == "Running" ? "Running \(action.rawValue)…" : "Planning locally…"
                    })
                status = "Completed"; outcome = "completed"
            } catch {
                status = cancellation.isCancelled ? "Stopped" : "Could not complete"
                summary = error.localizedDescription
                for index in activities.indices where activities[index].state == "Running" { activities[index].state = "Failed" }
                outcome = cancellation.isCancelled ? "cancelled" : "failed"
            }
            history.append(.init(id: UUID(), date: Date(), provider: model.identifier, outcome: outcome,
                actions: activities.map { $0.action.rawValue }))
            history = Array(history.suffix(100))
            saveJournal()
            running = false; self.cancellation = nil; run = nil
        }
    }

    func stop() { status = "Stopping…"; cancellation?.cancel(); run?.cancel() }
    func unload() { guard !running else { return }; Task { await mlx.unload() }; status = "Local model unloaded" }

    private static func execute(_ step: AgentStep, bridge: HubAgentBridge) throws -> String {
        _ = try step.validated()
        let command: String
        var args: [String: Any] = ["limit": 5]
        switch step.action {
        case .status: command = "status"
        case .findFeeds: command = "feeds.list"; args["query"] = step.query
        case .feedDetails: command = "feeds.get"; args["id"] = step.id
        case .openLive: command = "feeds.open_live"; args["id"] = step.id
        case .showPane: command = "ui.show"; args["pane"] = step.pane
        case .reviewQueue: command = "review.list"
        case .findRecords: command = "records.list"; args["collection"] = "incidents"; args["query"] = step.query
        case .finish: throw AgentFailure.invalidPlan
        }
        var value = try bridge.execute(command, data: JSONSerialization.data(withJSONObject: args))
        if step.action == .status { value.removeValue(forKey: "assistant_status"); value.removeValue(forKey: "assistant_actions") }
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
        return String(String(decoding: data, as: UTF8.self).prefix(3000))
    }

    private static var journalURL: URL {
        let root = HubQAFixture.enabled ? HubQAFixture.directory
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("PlateWatchHub")
        return root.appendingPathComponent("Assistant/activity.json")
    }
    private func saveJournal() {
        do {
            let url = Self.journalURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try JSONEncoder.withISODates.encode(history).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            journalError = nil
        } catch { journalError = "Could not save the local action journal." }
    }
}
