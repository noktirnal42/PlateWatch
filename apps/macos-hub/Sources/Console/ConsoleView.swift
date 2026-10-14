import AVFoundation
import FeedIngest
import SwiftUI

/// The Hub's main window: one place to see and control every source, the analysis models, review, and
/// (for enrolled moderators only) moderation.
struct ConsoleView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard", feeds = "Public feeds", cameras = "Cameras & ingest", models = "Models"
        case moderation = "Moderation", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.33percent"
            case .feeds: return "antenna.radiowaves.left.and.right"
            case .cameras: return "video"
            case .models: return "cpu"
            case .moderation: return "checkmark.shield"
            case .settings: return "gearshape"
            }
        }
    }

    @ObservedObject var hub: HubController
    @State private var selection: Pane? = .dashboard
    @State private var moderator = ModeratorAccess.isEnrolled

    private var panes: [Pane] { Pane.allCases.filter { $0 != .moderation || moderator } }

    var body: some View {
        NavigationSplitView {
            List(panes, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            Group {
                switch selection ?? .dashboard {
                case .dashboard: DashboardPane(hub: hub)
                case .feeds: FeedsPane(hub: hub)
                case .cameras: CamerasPane(hub: hub)
                case .models: ModelsPane(hub: hub)
                case .moderation: ModerationPane(onSignOut: { moderator = false; selection = .dashboard })
                case .settings: SettingsPane(hub: hub, moderator: $moderator)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationTitle(selection?.rawValue ?? "PlateWatch Hub")
        .frame(minWidth: 860, minHeight: 540)
    }
}

private struct Stat: View {
    let title: String, value: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.system(.title, design: .rounded).monospacedDigit()).bold()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(12).frame(minWidth: 140, alignment: .leading)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}

struct DashboardPane: View {
    @ObservedObject var hub: HubController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(spacing: 12) {
                    Stat(title: "Frames analysed", value: "\(hub.framesAnalyzed)")
                    Stat(title: "Fleet hits today", value: "\(hub.fleetHitsToday)")
                    Stat(title: "Outbox pending", value: "\(hub.pendingCount)")
                }
                GroupBox("Sources") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Analysis", value: hub.modelStatus)
                        LabeledContent("Snapshot server", value: hub.snapshotServerStatus)
                        LabeledContent("RTSP streams", value: hub.rtspServerStatus)
                        LabeledContent("Ingest folder", value: hub.ingestFolder.path)
                        FeedStatusRow(runner: hub.feedRunner)
                    }.padding(4)
                }
                GroupBox("Plate reading") {
                    Text(hub.platesAllowed
                         ? "Enabled for this Hub's location."
                         : "Off: no home location set, or a jurisdiction that restricts plate recognition. Set the home geohash in Settings.")
                        .padding(4)
                }
            }.padding()
        }
    }
}

struct FeedsPane: View {
    @ObservedObject var hub: HubController
    @Environment(\.openWindow) private var openWindow
    @State private var catalogue: FeedCatalogue?
    @State private var query = ""

    private var rows: [PublicFeedSource] {
        let all = catalogue?.sources ?? []
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.url.host ?? "").contains(query.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                FeedStatusRow(runner: hub.feedRunner)
                Spacer()
                Button("Import Austin cameras") { Task { await hub.importAustinCameras(); reload() } }
                Button("Review terms…") { openWindow(id: "feeds-review") }
                Button("Reveal feeds.json") { hub.revealFeedsFile() }
            }
            if !hub.importStatus.isEmpty { Text(hub.importStatus).font(.caption).foregroundStyle(.secondary) }
            Table(rows) {
                TableColumn("Camera") { Text($0.name) }
                TableColumn("Host") { Text($0.url.host ?? "") }
                TableColumn("Location") { Text($0.geohash6.isEmpty ? "unknown" : $0.geohash6).monospaced() }
                TableColumn("Terms") { s in
                    Label(s.mayBeAnalysed ? "Confirmed" : "Awaiting terms",
                          systemImage: s.mayBeAnalysed ? "checkmark.circle.fill" : "hourglass")
                        .foregroundStyle(s.mayBeAnalysed ? .green : .orange)
                }
            }
            .searchable(text: $query, prompt: "Filter cameras")
            Text("\(rows.count) of \(catalogue?.sources.count ?? 0) sources. Only sources whose terms a person confirmed are polled, and robots.txt is honoured.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: hub.feedRunner.status) { _, _ in reload() }
    }

    private func reload() { catalogue = try? FeedCatalogue.load(from: hub.feedsFile) }
}

struct CamerasPane: View {
    @ObservedObject var hub: HubController
    @State private var rtspURL = ""
    @State private var devices: [AVCaptureDevice] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Wi-Fi / IP cameras") {
                    VStack(alignment: .leading, spacing: 8) {
                        LabeledContent("Snapshot endpoint", value: hub.snapshotPort == 0 ? hub.snapshotServerStatus
                                       : "http://<this-mac>:\(hub.snapshotPort)/snapshot (Bonjour: _platewatch-snapshot._tcp)")
                        LabeledContent("Watched folder", value: hub.ingestFolder.path)
                        Button("Choose folder…") { hub.chooseIngestFolder() }
                    }.padding(4)
                }
                GroupBox("RTSP streams") {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            TextField("rtsp://camera.local/stream", text: $rtspURL).textFieldStyle(.roundedBorder)
                            Button("Start") { hub.startRTSPStream(url: rtspURL); rtspURL = "" }
                                .disabled(!rtspURL.lowercased().hasPrefix("rtsp://"))
                        }
                        ForEach(hub.rtspStreams.keys.sorted(), id: \.self) { url in
                            let s = hub.rtspStreams[url]
                            HStack {
                                Text(url).monospaced().lineLimit(1)
                                Spacer()
                                Text("\(s?.status ?? "") · \(s?.framesAnalyzed ?? 0) frames · \(s?.fleetHits ?? 0) hits").font(.caption)
                                Button("Stop") { hub.stopRTSPStream(url: url) }
                            }
                        }
                    }.padding(4)
                }
                GroupBox("Cameras on this Mac (incl. iPhone via Continuity Camera)") {
                    VStack(alignment: .leading, spacing: 6) {
                        if devices.isEmpty { Text("None found.").foregroundStyle(.secondary) }
                        ForEach(devices, id: \.uniqueID) { Label($0.localizedName, systemImage: "camera") }
                        Text("Detected only. Live capture into the analysis pipeline is the next slice.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
            }.padding()
        }
        .onAppear {
            devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera, .external, .continuityCamera],
                                                       mediaType: .video, position: .unspecified).devices
        }
    }
}

struct ModelsPane: View {
    @ObservedObject var hub: HubController
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledContent("Analysis", value: hub.modelStatus)
            Button("Check for model updates") { Task { await hub.refreshModels() } }
            Text("Detectors install from models/registry.json (SHA-256 pinned). A developer override in Application Support › PlateWatchHub › Models › Local takes precedence. Everything runs on this Mac; no frames leave it.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}

struct SettingsPane: View {
    @ObservedObject var hub: HubController
    @Binding var moderator: Bool
    @AppStorage("hubGeohash6") private var geohash = ""
    @AppStorage("hubSnapshotPort") private var port = 8088
    @State private var server = ""
    @State private var token = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section("Hub") {
                TextField("Home geohash (6)", text: $geohash).onChange(of: geohash) { _, v in hub.homeGeohash6 = v }
                TextField("Preferred snapshot port", value: $port, format: .number.grouping(.never))
                    .onSubmit { Task { await hub.restartSnapshotServer(port: UInt16(clamping: port)) } }
            }
            if ModeratorAccess.enrollmentOffered || moderator {
                Section("Moderator") {
                    if moderator {
                        Text("Enrolled for \(ModeratorAccess.serverURL?.host ?? "?")")
                        Button("Sign out") { ModeratorAccess.remove(); moderator = false }
                    } else {
                        TextField("Server URL (https://…)", text: $server)
                        SecureField("Moderator token", text: $token)
                        Button("Enrol") {
                            if let url = URL(string: server), url.scheme == "https" || url.host == "127.0.0.1" || url.host == "localhost",
                               ModeratorAccess.enroll(token: token, server: url) {
                                token = ""; moderator = true; note = ""
                            } else { note = "Enter an https:// server URL (or localhost) and a token." }
                        }.disabled(server.isEmpty || token.isEmpty)
                        if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.red) }
                    }
                }
            }
        }
        .formStyle(.grouped).padding()
    }
}
