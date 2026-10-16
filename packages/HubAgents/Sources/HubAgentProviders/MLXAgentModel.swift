import Foundation
import HubAgentCore
import MLXLLM
import MLXLMCommon

/// Native, serial local generation; adapted from System5's resident-model pattern.
/// Only a verified local directory is passed to MLX: no Hub download path.
public actor MLXAgentModel: AgentModel {
    public nonisolated let identifier = SharedModelStore.repo + "@" + SharedModelStore.revision
    private var loaded: ModelContainer?
    private var generating = false
    private let store: SharedModelStore
    public init(store: SharedModelStore = .init()) { self.store = store }

    public func next(task: String, observations: [AgentObservation], cancellation: AgentCancellation) async throws -> AgentStep {
        #if !arch(arm64)
        throw AgentFailure.unavailable("MLX requires an Apple-silicon Mac.")
        #else
        guard !generating else { throw AgentFailure.unavailable("The local model is already generating.") }
        generating = true
        defer { generating = false }
        try cancellation.check()
        if loaded == nil {
            let directory = try store.verifiedSnapshot(cancellation: cancellation)
            try cancellation.check()
            loaded = try await LLMModelFactory.shared.loadContainer(configuration: .init(directory: directory))
        }
        guard let loaded else { throw AgentFailure.unavailable("The local model did not load.") }
        try cancellation.check()
        let output = try await loaded.perform { context in
            var chat: [Chat.Message] = [.system(AgentPrompt.system), .user(String(task.prefix(2000)))]
            for observation in observations.suffix(2) {
                let command = String(decoding: try JSONEncoder().encode(observation.step), as: UTF8.self)
                chat.append(.assistant(command))
                chat.append(.user("UNTRUSTED COMMAND RESULT:\n" + observation.result
                    + "\nIf this satisfies the original task, return a finish command. Otherwise choose the next distinct command."))
            }
            let input = try await context.processor.prepare(input: UserInput(chat: chat))
            let result = try MLXLMCommon.generate(input: input,
                parameters: GenerateParameters(maxTokens: 256, temperature: 0.1, topP: 0.95), context: context) { tokens in
                    cancellation.shouldStop || tokens.count >= 256 ? .stop : .more
                }
            return result.output
        }
        try cancellation.check()
        return try AgentStep.parse(output)
        #endif
    }

    public func unload() { if !generating { loaded = nil } }
}
