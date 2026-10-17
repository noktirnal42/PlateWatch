import Foundation
import FoundationModels
import HubAgentCore

public struct AppleAgentModel: AgentModel {
    public static let defaultModelIdentifier = "apple.foundation-models.default"
    public let modelIdentifier: String
    public var identifier: String { modelIdentifier + " · Apple Foundation Models · on device" }
    public init(modelIdentifier: String = AppleAgentModel.defaultModelIdentifier) {
        self.modelIdentifier = modelIdentifier
    }
    public static var availability: String? {
        guard #available(macOS 26, *) else { return "Requires macOS 26 or later." }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.deviceNotEligible): return "This Mac is not eligible for Apple Intelligence."
        case .unavailable(.appleIntelligenceNotEnabled): return "Enable Apple Intelligence in System Settings."
        case .unavailable(.modelNotReady): return "The on-device model is not ready; its assets may still be downloading."
        case .unavailable: return "Apple Intelligence is unavailable."
        }
    }
    public func next(task: String, observations: [AgentObservation], cancellation: AgentCancellation) async throws -> AgentStep {
        guard #available(macOS 26, *) else { throw AgentFailure.unavailable("Requires macOS 26 or later.") }
        if let reason = Self.availability { throw AgentFailure.unavailable(reason) }
        try cancellation.check()
        let session = LanguageModelSession(model: .default, instructions: AgentPrompt.system)
        var text = ""
        for try await snapshot in session.streamResponse(to: AgentPrompt.user(task: task, observations: observations),
            options: GenerationOptions(temperature: 0.1, maximumResponseTokens: 256)) {
            try cancellation.check()
            text = snapshot.content
            guard text.utf8.count <= 4096 else { throw AgentFailure.invalidPlan }
        }
        return try AgentStep.parse(text)
    }
}
