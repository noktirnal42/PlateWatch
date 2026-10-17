import Foundation
import HubAgentCore

/// Explicit hosted provider; only sanitized public observations reach this adapter.
public struct NIMAgentModel: AgentModel {
    public let model: String
    public var identifier: String { model + " · NVIDIA hosted" }
    private let client: NIMClient
    public init(client: NIMClient, model: String = NIMClient.agentModel) {
        self.client = client
        self.model = model
    }
    public func next(task: String, observations: [AgentObservation], cancellation: AgentCancellation) async throws -> AgentStep {
        try cancellation.check()
        guard observations.allSatisfy({ ![AgentAction.reviewQueue, .findRecords].contains($0.action) }) else { throw NIMError.invalidInput }
        let prompt = AgentPrompt.system + "\nThis is hosted NVIDIA inference. reviewQueue and findRecords are unavailable. Do not request them."
        let body = try NIMClient.encode(["model": model, "stream": false, "max_tokens": 512,
            "temperature": 1.0, "top_p": 0.95, "chat_template_kwargs": ["enable_thinking": false],
            "messages": [["role": "system", "content": prompt], ["role": "user", "content": AgentPrompt.user(task: task, observations: observations)]]])
        let data = try await client.post(.chat, body: body)
        try cancellation.check()
        return try AgentStep.parse(NIMClient.chatText(data))
    }
}
