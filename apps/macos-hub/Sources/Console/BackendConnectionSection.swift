import CloudKit
import PlateSync
import SwiftUI

/// Read-only probes. Opening Settings must never drain the review queue.
struct BackendConnectionSection: View {
    @State private var cloudKit = "Not checked"
    @State private var server = "Not checked"
    @State private var checking = false
    @State private var lastChecked: Date?

    var body: some View {
        Section("Backend connections") {
            connectionRow(title: "CloudKit", value: cloudKit, systemImage: "icloud")
            connectionRow(title: "Reference server", value: server, systemImage: "server.rack")
            Text("Local review items remain on this Mac. Automatic outbox delivery is not enabled. Server moderation and CloudKit publication are separate paths; CloudKit publication tooling is still pending.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Button(checking ? "Checking…" : "Check connections", systemImage: "arrow.clockwise") { Task { await check() } }
                    .disabled(checking)
                if let lastChecked {
                    Text("Checked (lastChecked, format: .dateTime.hour().minute().second())")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task { await check() }
    }

    @MainActor
    private func check() async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        cloudKit = "Checking…"
        server = "Checking…"
        async let cloudResult = checkCloudKit()
        async let serverResult = checkServer()
        let results = await (cloudResult, serverResult)
        guard !Task.isCancelled else { return }
        cloudKit = results.0
        server = results.1
        lastChecked = Date()
    }

    @ViewBuilder
    private func connectionRow(title: String, value: String, systemImage: String) -> some View {
        LabeledContent {
            HStack(spacing: 6) {
                Image(systemName: statusIcon(for: value))
                    .foregroundStyle(statusColor(for: value))
                Text(value).multilineTextAlignment(.trailing)
            }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    private func statusIcon(for value: String) -> String {
        if value == "Checking…" { return "hourglass" }
        if value.localizedCaseInsensitiveContains("connected") || value.localizedCaseInsensitiveContains("reachable") { return "checkmark.circle.fill" }
        if value.localizedCaseInsensitiveContains("not checked") { return "questionmark.circle" }
        return "exclamationmark.triangle.fill"
    }

    private func statusColor(for value: String) -> Color {
        if value == "Checking…" || value.localizedCaseInsensitiveContains("not checked") { return .secondary }
        if value.localizedCaseInsensitiveContains("connected") || value.localizedCaseInsensitiveContains("reachable") { return .green }
        return .orange
    }

    private func checkCloudKit() async -> String {
        guard SyncBackends.cloudKitAvailable() else { return "Unavailable — this build has no CloudKit entitlement" }
        do {
            let container = CKContainer(identifier: SyncBackends.containerID)
            switch try await container.accountStatus() {
            case .available:
                do {
                    _ = try await container.userRecordID()
                    return "Connected · account and container record access available"
                } catch {
                    return "Account available · container record access failed (\((error as NSError).code))"
                }
            case .noAccount: return "Sign in to iCloud in System Settings"
            case .restricted: return "iCloud access is restricted"
            case .temporarilyUnavailable: return "iCloud temporarily unavailable"
            case .couldNotDetermine: return "Could not determine iCloud account status"
            @unknown default: return "Unknown iCloud account status"
            }
        } catch { return "Account check failed (\((error as NSError).domain), \((error as NSError).code))" }
    }

    private func checkServer() async -> String {
        let url = ModeratorAccess.serverURL ?? SyncBackends.mirrorURL()
        var request = URLRequest(url: url.appending(path: "health"))
        request.timeoutInterval = 8
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let response = response as? HTTPURLResponse else { return "Invalid health response" }
            guard response.statusCode == 200,
                  let body = try? JSONDecoder().decode([String: String].self, from: data), body["status"] == "ok"
            else { return "Health check failed · HTTP \(response.statusCode)" }
            return "Reachable · \(url.absoluteString) · health only"
        } catch { return "Offline · \(url.absoluteString) (\((error as NSError).code))" }
    }
}
