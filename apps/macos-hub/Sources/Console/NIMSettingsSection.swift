import SwiftUI

struct NIMSettingsSection: View {
    @State private var key = ""
    @State private var message = "Not checked"
    @State private var busy = false
    var body: some View {
        Section("NVIDIA hosted models") {
            Text("Optional hosted inference. Assistant sends your task and public feed diagnostics. NVIDIA research sends only the public text or image you explicitly choose; local Review evidence is excluded.")
                .font(.caption).foregroundStyle(.secondary)
            SecureField("NVIDIA API key", text: $key)
            HStack {
                Button("Save NVIDIA key") { perform { let saved = await NIMCredentials.save(key); if saved { key = "" }; return saved ? "Saved in this Mac’s Keychain" : "Could not save key; check its format and Keychain access" } }
                    .disabled(key.isEmpty || busy)
                Button("Remove NVIDIA key") { perform { await NIMCredentials.remove() ? "Key removed" : "Could not remove key" } }.disabled(busy)
            }
            Text(message).font(.caption)
            Button("Open NVIDIA research") { NotificationCenter.default.post(name: HubAgentBridge.navigation, object: "research") }
        }.task { message = await NIMCredentials.load() == nil ? "No NVIDIA key saved" : "NVIDIA key saved · service access not tested" }
    }
    private func perform(_ action: @escaping @MainActor () async -> String) {
        busy = true
        Task { message = await action(); busy = false }
    }
}
