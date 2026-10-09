import SwiftUI

@main
struct PlateWatchHubApp: App {
    var body: some Scene {
        MenuBarExtra("PlateWatch Hub", systemImage: "antenna.radiowaves.left.and.right") {
            HubStatusView()
        }
        .menuBarExtraStyle(.window)
    }
}

/// Menu-bar status + controls for the fixed-camera hub. The hub ingests
/// snapshots from IP cameras (they FTP/POST images on motion) plus a local
/// Continuity Camera source, runs the shared pipeline, and keeps the local
/// archive + outbox.
struct HubStatusView: View {
    @StateObject private var hub = HubController()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("PlateWatch Hub", systemImage: "building.columns")
                .font(.headline)
            Divider()
            row("Ingest folder", hub.ingestFolder.path)
            row("Frames analyzed", "\(hub.framesAnalyzed)")
            row("Fleet hits today", "\(hub.fleetHitsToday)")
            row("Outbox", "\(hub.pendingCount) pending")
            Divider()
            HStack {
                Button("Choose Folder…") { hub.chooseIngestFolder() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 300)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospaced()
        }
    }
}
