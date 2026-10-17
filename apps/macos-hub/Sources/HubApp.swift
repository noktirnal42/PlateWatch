import PlateSync
import SwiftData
import SwiftUI

@main
struct PlateWatchHubApp: App {
    let modelContainer: ModelContainer
    /// Owned here so ingest (folder watch + snapshot server) starts at launch, not when the
    /// menu-bar popover is first opened.
    @StateObject private var hub: HubController

    init() {
        let schema = Schema([PendingSubmission.self, ReceivedSubmissionReceipt.self])
        // This is a local review queue, never an implicit SwiftData/CloudKit store.
        let config = ModelConfiguration("PlateWatchHub", schema: schema, isStoredInMemoryOnly: HubQAFixture.enabled, cloudKitDatabase: .none)
        modelContainer = (try? ModelContainer(for: schema, configurations: config))
            // A hub with no local persistence still runs degraded (log-only).
            ?? (try! ModelContainer(for: schema, configurations:
                ModelConfiguration("PlateWatchHub-fallback", schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)))
        HubQAFixture.prepare(context: modelContainer.mainContext)
        let controller = HubController(context: modelContainer.mainContext)
        let bridge = HubAgentBridge(hub: controller, context: modelContainer.mainContext)
        controller.agentBridge = bridge
        if !HubQAFixture.enabled { bridge.start() }
        _hub = StateObject(wrappedValue: controller)
        let port = UInt16(clamping: UserDefaults.standard.integer(forKey: "hubSnapshotPort"))
        if !HubQAFixture.enabled { Task { await controller.startSnapshotServer(port: port == 0 ? 8088 : port) } }
    }

    var body: some Scene {
        // The main desktop console.
        Window("PlateWatch Hub", id: "console") {
            ConsoleView(hub: hub)
                .modelContainer(modelContainer)
                .onAppear { hub.attach(context: modelContainer.mainContext) }
        }
        .defaultSize(width: 1180, height: 740)
        .commands { HubWindowCommands() }

        MenuBarExtra("PlateWatch Hub", systemImage: "antenna.radiowaves.left.and.right") {
            HubStatusView(hub: hub)
        }
        .menuBarExtraStyle(.window)
        .modelContainer(modelContainer)

        Window("PlateWatch Hub Help", id: "hub-help") {
            HubHelpView()
        }.defaultSize(width: 660, height: 650)

        // Feed terms review window
        Window("Feed terms", id: "feeds-review") {
            FeedsReviewView(hub: hub)
        }
    }
}

/// Menu-bar status + controls for the fixed-camera hub. The hub ingests
/// snapshots from IP cameras (they FTP/POST images on motion) plus a local
/// Continuity Camera source, runs the shared pipeline, and keeps the local
/// archive + outbox.
/// Observes the feed runner directly (a nested ObservableObject is not observed through its owner).
struct FeedStatusRow: View {
    @ObservedObject var runner: FeedRunner
    var body: some View {
        HStack {
            Text("Public feeds").foregroundStyle(.secondary)
            Spacer()
            Text(runner.status).font(.caption).multilineTextAlignment(.trailing)
        }
    }
}

struct HubStatusView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var hub: HubController
    @AppStorage("hubGeohash6") private var hubGeohash6 = ""
    @AppStorage("hubSnapshotPort") private var snapshotPortSetting = 8088

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("PlateWatch Hub", systemImage: "building.columns")
                .font(.headline)
            Divider()
            row("Ingest folder", hub.ingestFolder.path)
            row("Frames analyzed", "\(hub.framesAnalyzed)")
            row("Fleet hits today", "\(hub.fleetHitsToday)")
            row("Outbox", "\(hub.pendingCount) pending")
            row("Snapshot server", hub.snapshotServerStatus)
            FeedStatusRow(runner: hub.feedRunner)
            HStack {
                Button("Import Austin cameras") { Task { await hub.importAustinCameras() } }
                Button("Reveal feeds.json") { hub.revealFeedsFile() }
            }
            HStack {
                Button("Review feed terms…") { openWindow(id: "feeds-review") }
                Spacer()
            }
            if !hub.importStatus.isEmpty { Text(hub.importStatus).font(.caption).foregroundStyle(.secondary) }
            HStack {
                Text("Preferred port").foregroundStyle(.secondary)
                Spacer()
                TextField("8088", value: $snapshotPortSetting, format: .number.grouping(.never))
                    .frame(width: 80)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await hub.restartSnapshotServer(port: UInt16(clamping: snapshotPortSetting)) } }
            }
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

private struct HubWindowCommands: Commands {
    @Environment(\.openWindow) private var openWindow
    @AppStorage("hubAppearance") private var appearance = "system"
    private let destinations: [ConsoleView.Pane] = [.dashboard, .live, .feeds, .cameras, .review, .models, .records, .settings, .assistant]
    var body: some Commands {
        CommandMenu("Navigate") {
            ForEach(Array(destinations.enumerated()), id: \.element.id) { index, pane in
                Button(pane.rawValue, systemImage: pane.icon) {
                    openWindow(id: "console")
                    NotificationCenter.default.post(name: HubAgentBridge.navigation, object: String(describing: pane))
                }.keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
        }
        CommandMenu("Appearance") {
            Picker("Color scheme", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
        }
        CommandGroup(replacing: .help) {
            Button("PlateWatch Hub Help") { openWindow(id: "hub-help") }
                .keyboardShortcut("?", modifiers: .command)
        }
        CommandGroup(after: .newItem) {
            Button("Show PlateWatch Console") { openWindow(id: "console") }
                .keyboardShortcut("0", modifiers: .command)
        }
    }
}
