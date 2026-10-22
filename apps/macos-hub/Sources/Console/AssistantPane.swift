import SwiftUI
import HubAgentProviders
import NIMKit

struct AssistantPane: View {
    let hub: HubController
    @ObservedObject var assistant: HubAssistant
    @State private var provider: HubAssistant.Provider = .mlx
    @State private var modelID = ""
    @AppStorage("hubAssistantProvider") private var savedProvider = HubAssistant.Provider.mlx.rawValue
    @AppStorage("hubAssistantMLXModel") private var savedMLXModel = ""
    @AppStorage("hubAssistantAppleModel") private var savedAppleModel = AppleAgentModel.defaultModelIdentifier
    @AppStorage("hubAssistantNVIDIAModel") private var savedNVIDIAModel = NIMClient.agentModel
    @State private var taskText = "Check current Hub status, then finish."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Assistant", systemImage: "sparkles").font(.title2.bold())
                Spacer()
                Text(assistant.status).font(.callout).foregroundStyle(.secondary)
            }
            Text(provider == .nvidia ? "Hosted NVIDIA: sends this task and public feed diagnostics. Queue and local record tools are unavailable. Six steps per run; no evidence approval or publication." : "Ask about feeds, check the queue or cited records, or open a pane. Processing stays on this Mac. Six steps per run; no evidence approval or publication.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Provider", selection: $provider) {
                    ForEach(HubAssistant.Provider.allCases) { item in Text(item.rawValue).tag(item) }
                }.frame(maxWidth: 220).disabled(assistant.running)
                Picker("Model", selection: $modelID) {
                    ForEach(assistant.modelChoices(for: provider)) { choice in
                        VStack(alignment: .leading) { Text(choice.name); Text(choice.detail).font(.caption) }.tag(choice.id)
                    }
                }.frame(maxWidth: 310).disabled(assistant.running)
                Text(assistant.availability(provider)).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
            TextEditor(text: $taskText).font(.body).frame(height: 72)
                .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Assistant task").disabled(assistant.running)
            HStack {
                Button("Run task", systemImage: "play.fill") { assistant.start(task: taskText, provider: provider, modelID: modelID, bridge: hub.agentBridge) }
                    .buttonStyle(HUDProminentButtonStyle()).disabled(assistant.running || taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Stop", systemImage: "stop.fill") { assistant.stop() }.disabled(!assistant.running)
                Button("Unload local model") { assistant.unload() }.disabled(assistant.running)
                if assistant.running { ProgressView().controlSize(.small).accessibilityLabel("Model is working") }
            }
            if !assistant.summary.isEmpty {
                GroupBox(assistant.status == "Completed" ? "Model summary — verify against command results" : "Run result") {
                    Text(assistant.summary).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(assistant.activities) { activity in
                        GroupBox {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(activity.action.rawValue).font(.headline); Spacer(); Text(activity.state).foregroundStyle(.secondary) }
                                if !activity.result.isEmpty { Text(activity.result).font(.system(.caption, design: .monospaced)).textSelection(.enabled) }
                            }.frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    if !assistant.history.isEmpty {
                        DisclosureGroup("Local run history (\(assistant.history.count))") {
                            ForEach(assistant.history.reversed()) { entry in
                                HStack {
                                    Text(entry.date, format: .dateTime)
                                    Text(entry.outcome)
                                    Text(entry.actions.joined(separator: ", ")).lineLimit(1)
                                }.font(.caption).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
            if let error = assistant.journalError { Text(error).font(.caption).foregroundStyle(.red) }
            Text("The journal saves model identity, command names and outcomes only. Task text, results, images, plates and credentials are not journaled. MLX uses the pinned shared cache; no automatic downloads. Private Cloud Compute is not enabled.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
        .onAppear {
            provider = HubAssistant.Provider(rawValue: savedProvider) ?? .mlx
            let stored = switch provider {
            case .mlx: savedMLXModel
            case .apple: savedAppleModel
            case .nvidia: savedNVIDIAModel
            }
            modelID = assistant.modelChoices(for: provider).contains(where: { $0.id == stored }) ? stored : assistant.defaultModel(for: provider)
        }
        .onChange(of: provider) { _, value in
            savedProvider = value.rawValue
            let stored = storedModel(for: value)
            modelID = assistant.modelChoices(for: value).contains(where: { $0.id == stored })
                ? stored
                : assistant.defaultModel(for: value)
        }
        .onChange(of: modelID) { _, value in
            switch provider {
            case .mlx: savedMLXModel = value
            case .apple: savedAppleModel = value
            case .nvidia: savedNVIDIAModel = value
            }
        }
    }

    private func storedModel(for provider: HubAssistant.Provider) -> String {
        switch provider {
        case .mlx: savedMLXModel
        case .apple: savedAppleModel
        case .nvidia: savedNVIDIAModel
        }
    }
}
