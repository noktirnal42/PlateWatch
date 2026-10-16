import SwiftUI

struct AssistantPane: View {
    let hub: HubController
    @ObservedObject var assistant: HubAssistant
    @State private var provider: HubAssistant.Provider = .mlx
    @State private var taskText = "Check current Hub status, then finish."

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Local assistant", systemImage: "sparkles").font(.title2.bold())
                Spacer()
                Text(assistant.status).font(.callout).foregroundStyle(.secondary)
            }
            Text("Ask about feeds, check the queue or cited records, or open a pane. Processing stays on this Mac. Six commands per run; no evidence approval or publication.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Picker("Model", selection: $provider) {
                    ForEach(HubAssistant.Provider.allCases) { item in Text(item.rawValue).tag(item) }
                }.frame(maxWidth: 340).disabled(assistant.running)
                Text(assistant.availability(provider)).font(.caption).foregroundStyle(.secondary)
            }
            TextEditor(text: $taskText).font(.body).frame(height: 72)
                .padding(6).background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                .accessibilityLabel("Assistant task").disabled(assistant.running)
            HStack {
                Button("Run task", systemImage: "play.fill") { assistant.start(task: taskText, provider: provider, bridge: hub.agentBridge) }
                    .buttonStyle(.borderedProminent).disabled(assistant.running || taskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Stop", systemImage: "stop.fill") { assistant.stop() }.disabled(!assistant.running)
                Button("Unload local model") { assistant.unload() }.disabled(assistant.running)
                if assistant.running { ProgressView().controlSize(.small).accessibilityLabel("Local model is working") }
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
    }
}
