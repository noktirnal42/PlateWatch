import CloudKit
import PlateSync
import SwiftUI

/// Read-only probes. Opening Settings must never drain the review queue.
struct BackendConnectionSection: View {
    @State private var cloudKit = "Not checked"
    @State private var server = "Not checked"
    @State private var checking = false

    var body: some View {
        Section("Backend connections") {
            LabeledContent("CloudKit", value: cloudKit)
            LabeledContent("Reference server", value: server)
            Text("Local review items remain on this Mac. Automatic outbox delivery is not enabled. Server moderation and CloudKit publication are separate paths; CloudKit publication tooling is still pending.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check connections") { Task { await check() } }.disabled(checking)
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
    }

    private func checkCloudKit() async -> String {
        guard SyncBackends.cloudKitAvailable() else { return "Unavailable — this build has no CloudKit entitlement" }
        do {
            switch try await CKContainer(identifier: SyncBackends.containerID).accountStatus() {
            case .available: return "iCloud account available · schema/record access not checked"
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
