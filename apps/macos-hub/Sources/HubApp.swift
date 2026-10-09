import PlateSync
import SwiftData
import SwiftUI

@main
struct PlateWatchHubApp: App {
    let modelContainer: ModelContainer
    let backend: any SyncBackend

    init() {
        let schema = Schema([PendingSubmission.self])
        let config = ModelConfiguration("PlateWatchHub", schema: schema)
        modelContainer = (try? ModelContainer(for: schema, configurations: config))
            // A hub with no local persistence still runs degraded (log-only).
            ?? (try! ModelContainer(for: schema, configurations:
                ModelConfiguration("PlateWatchHub-fallback", schema: schema, isStoredInMemoryOnly: true)))
        backend = CloudKitBackend()
    }

    var body: some Scene {
        MenuBarExtra("PlateWatch Hub", systemImage: "antenna.radiowaves.left.and.right") {
            HubStatusView()
        }
        .menuBarExtraStyle(.window)
        .modelContainer(modelContainer)
    }
}

/// Menu-bar status + controls for the fixed-camera hub. The hub ingests
/// snapshots from IP cameras (they FTP/POST images on motion) plus a local
/// Continuity Camera source, runs the shared pipeline, and keeps the local
/// archive + outbox.
struct HubStatusView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var hub = HubController()
    @AppStorage("hubGeohash6") private var hubGeohash6 = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("PlateWatch Hub", systemImage: "building.columns")
                .font(.headline)
            Divider()
            row("Ingest folder", hub.ingestFolder.path)
            row("Frames analyzed", "\(hub.framesAnalyzed)")
            row("Fleet hits today", "\(hub.fleetHitsToday)")
            row("Outbox", "\(hub.pendingCount) pending")
            HStack {
                Text("Home geohash").foregroundStyle(.secondary)
                Spacer()
                TextField("e.g. 9v6kpv", text: $hubGeohash6)
                    .frame(width: 120)
                    .textFieldStyle(.roundedBorder)
            }
            Divider()
            HStack {
                Button("Choose Folder…") { hub.chooseIngestFolder() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear { hub.attach(context: modelContext) }
        .onChange(of: hubGeohash6) { _, value in hub.homeGeohash6 = value }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospaced()
        }
    }
}
