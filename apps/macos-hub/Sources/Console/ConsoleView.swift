import AVFoundation
import FeedIngest
import SwiftUI

/// The Hub's main window: one place to see and control every source, the analysis models, review, and
/// (for enrolled moderators only) moderation.
struct ConsoleView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard", live = "Live", feeds = "Public feeds", cameras = "Cameras & ingest", review = "Review", models = "Models", records = "Records & FOIA"
        case moderation = "Moderation", settings = "Settings"
        var id: String { rawValue }
        var icon: String {
            switch self {
            case .dashboard: return "gauge.with.dots.needle.33percent"
            case .live: return "eye"
            case .review: return "tray.full"
            case .feeds: return "antenna.radiowaves.left.and.right"
            case .cameras: return "video"
            case .models: return "cpu"
            case .records: return "doc.text.magnifyingglass"
            case .moderation: return "checkmark.shield"
            case .settings: return "gearshape"
            }
        }
    }

    let hub: HubController
    @Environment(\.openWindow) private var openWindow
    @State private var selection: Pane? = .dashboard
    @State private var feedsVisited = false
    @AppStorage("hubAppearance") private var appearance = "system"
    /// Whether a moderator credential exists. Read off the main thread: a Keychain access prompt must never freeze the window.
    @State private var moderator = false

    private var panes: [Pane] { Pane.allCases.filter { $0 != .moderation || moderator } }

    var body: some View {
        NavigationSplitView {
            List(panes, selection: $selection) { pane in
                Label(pane.rawValue, systemImage: pane.icon).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 200)
        } detail: {
            ZStack {
                // Mount on first visit, then retain browser controls and native scroll on navigation.
                if selection == .feeds || feedsVisited {
                    FeedsPane(hub: hub, isActive: selection == .feeds, onOpenLive: { selection = .live })
                        .opacity(selection == .feeds ? 1 : 0)
                        .allowsHitTesting(selection == .feeds)
                        .accessibilityHidden(selection != .feeds)
                }
                Group {
                switch selection ?? .dashboard {
                case .dashboard: DashboardPane(hub: hub)
                case .live: LivePane(hub: hub)
                case .review: ReviewPane()
                case .feeds: Color.clear.allowsHitTesting(false).accessibilityHidden(true)
                case .cameras: CamerasPane(hub: hub)
                case .models: ModelsPane(hub: hub)
                case .records: RecordsPane()
                case .moderation: ModerationPane(onSignOut: { moderator = false; selection = .dashboard })
                case .settings: SettingsPane(hub: hub, moderator: $moderator)
                }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .onChange(of: selection) { _, pane in
            if pane == .feeds { feedsVisited = true }
            hub.agentBridge?.currentPane = String(describing: pane ?? .dashboard)
        }
        .onAppear { hub.agentBridge?.currentPane = String(describing: selection ?? .dashboard) }
        .onDisappear { hub.agentBridge?.currentPane = "closed" }
        .onReceive(NotificationCenter.default.publisher(for: HubAgentBridge.navigation)) { note in
            if let key = note.object as? String {
                selection = Pane.allCases.first { String(describing: $0) == key } ?? selection
            }
        }
        .task { moderator = await Task.detached { ModeratorAccess.isEnrolled }.value }
        .navigationTitle(selection?.rawValue ?? "PlateWatch Hub")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Hub Help", systemImage: "questionmark.circle") { openWindow(id: "hub-help") }
                    .help("Feed status, favorites, blocks and Live analysis (⌘?)")
            }
        }
        .preferredColorScheme(appearance == "light" ? .light : appearance == "dark" ? .dark : nil)
        .frame(minWidth: 1000, minHeight: 600)
    }
}

private struct Stat: View {
    let title: String, value: String
    var icon = "chart.bar"
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint)
            Text(value).font(.system(.title, design: .rounded).monospacedDigit()).bold()
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .combine)
    }
}

struct DashboardPane: View {
    @ObservedObject var hub: HubController
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Your fleet observatory").font(.largeTitle.bold())
                    Text("On-device analysis · fleet-only evidence · counts for this session")
                        .foregroundStyle(.secondary)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150))], spacing: 12) {
                    Stat(title: "Frames analysed", value: "\(hub.framesAnalyzed)", icon: "viewfinder")
                    Stat(title: "Public feed frames", value: "\(hub.feedFramesAnalyzed)", icon: "antenna.radiowaves.left.and.right")
                    Stat(title: "Fleet hits today", value: "\(hub.fleetHitsToday)", icon: "car.side")
                    Stat(title: "Skipped while busy", value: "\(hub.framesDropped)", icon: "pause.circle")
                    Stat(title: "Outbox pending", value: "\(hub.pendingCount)", icon: "tray.and.arrow.up")
                }
                HStack(spacing: 12) {
                    dashboardAction("Browse cameras", icon: "antenna.radiowaves.left.and.right", pane: "feeds")
                    dashboardAction("Review evidence", icon: "tray.full", pane: "review")
                    dashboardAction("Records & FOIA", icon: "doc.text.magnifyingglass", pane: "records")
                }.buttonStyle(.bordered)
                GroupBox("Sources") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("Analysis", value: hub.modelStatus)
                        LabeledContent("Snapshot server", value: hub.snapshotServerStatus)
                        LabeledContent("RTSP streams", value: hub.rtspServerStatus)
                        LabeledContent("Ingest folder") {
                            Text(hub.ingestFolder.lastPathComponent).help(hub.ingestFolder.path)
                                .textSelection(.enabled)
                        }
                        FeedStatusRow(runner: hub.feedRunner)
                    }.padding(4)
                }
                GroupBox("Plate reading") {
                    Text(hub.platesAllowed
                         ? "Enabled for this Hub's location."
                         : "Off: no home location set (or none we can place in the US). Set the home location in Settings.")
                        .padding(4)
                }
            }.padding(24)
        }
    }

    private func dashboardAction(_ title: String, icon: String, pane: String) -> some View {
        Button(title, systemImage: icon) {
            NotificationCenter.default.post(name: HubAgentBridge.navigation, object: pane)
        }.help("Open \(title.lowercased())")
    }
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
                        Text("Open the Live pane to analyse a camera or a video file.")
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
    @AppStorage("hubAppearance") private var appearance = "system"
    @State private var server = ""
    @State private var token = ""
    @State private var note = ""

    var body: some View {
        Form {
            Section("Appearance") {
                Picker("Color scheme", selection: $appearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }.pickerStyle(.segmented)
                Text("Applies to the Hub console. Your Mac’s appearance stays unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HomeLocationSection(hub: hub, geohash: $geohash)
            Section("Hub") {
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
