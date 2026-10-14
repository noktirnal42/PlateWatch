import AVFoundation
import FeedIngest
import SwiftUI

/// The Hub's main window: one place to see and control every source, the analysis models, review, and
/// (for enrolled moderators only) moderation.
struct ConsoleView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case dashboard = "Dashboard", live = "Live", feeds = "Public feeds", cameras = "Cameras & ingest", review = "Review", models = "Models"
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
            case .moderation: return "checkmark.shield"
            case .settings: return "gearshape"
            }
        }
    }

    @ObservedObject var hub: HubController
    @State private var selection: Pane? = .dashboard
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
            Group {
                switch selection ?? .dashboard {
                case .dashboard: DashboardPane(hub: hub)
                case .live: LivePane(hub: hub)
                case .review: ReviewPane()
                case .feeds: FeedsPane(hub: hub)
                case .cameras: CamerasPane(hub: hub)
                case .models: ModelsPane(hub: hub)
                case .moderation: ModerationPane(onSignOut: { moderator = false; selection = .dashboard })
                case .settings: SettingsPane(hub: hub, moderator: $moderator)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .task { moderator = await Task.detached { ModeratorAccess.isEnrolled }.value }
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
                    Stat(title: "Frames skipped (busy)", value: "\(hub.framesDropped)")
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
                         : "Off: no home location set, or a jurisdiction that restricts plate recognition. Set the home location in Settings.")
                        .padding(4)
                }
            }.padding()
        }
    }
}

struct FeedsPane: View {
    @ObservedObject var hub: HubController
    @State private var catalogue: FeedCatalogue?
    @State private var query = ""
    @State private var reviewing: FeedHostSummary?
    @State private var selected: Set<UUID> = []

    private var hosts: [FeedHostSummary] { catalogue?.hosts() ?? [] }
    private var needReview: [FeedHostSummary] { hosts.filter { $0.confirmedCount < $0.totalCount } }

    private var rows: [PublicFeedSource] {
        let all = catalogue?.sources ?? []
        return query.isEmpty ? all : all.filter { $0.name.localizedCaseInsensitiveContains(query) || ($0.url.host ?? "").contains(query.lowercased()) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !needReview.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Cameras are not polled until you review and confirm each image host's terms.", systemImage: "hand.raised")
                        .font(.headline)
                    ForEach(needReview, id: \.host) { h in
                        HStack {
                            Text(h.host).monospaced()
                            Text("\(h.totalCount - h.confirmedCount) of \(h.totalCount) cameras waiting").foregroundStyle(.secondary)
                            Spacer()
                            Button("Review terms…") { reviewing = h }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(12).background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
            }
            HStack {
                FeedStatusRow(runner: hub.feedRunner)
                Spacer()
                Menu("Add cameras") {
                    Button("Texas — Austin traffic cameras (about 820)") { Task { await hub.importAustinCameras(); reload() } }
                    ForEach(HubController.OpenCatalogue.allCases) { c in
                        Button(c.rawValue) { Task { await hub.importCatalogue(c); reload() } }
                    }
                }
                Button("Reveal feeds.json") { hub.revealFeedsFile() }
            }
            if !hub.importStatus.isEmpty { Text(hub.importStatus).font(.caption).foregroundStyle(.secondary) }
            HSplitView {
            Table(rows, selection: $selected) {
                TableColumn("Camera") { Text($0.name) }
                TableColumn("Host") { Text($0.url.host ?? "") }
                TableColumn("Location") { Text($0.geohash6.isEmpty ? "unknown" : $0.geohash6).monospaced() }
                TableColumn("Status") { s in
                    let state = hub.feedRunner.state(of: s)
                    Label(state.text, systemImage: state.icon).foregroundStyle(state.color)
                }
            }
            .frame(minWidth: 420)
            CameraPreviewPanel(hub: hub, source: selected.first.flatMap { id in catalogue?.sources.first { $0.id == id } })
                .frame(minWidth: 300, idealWidth: 380)
            }
            .searchable(text: $query, prompt: "Filter cameras")
            Text("\(rows.count) of \(catalogue?.sources.count ?? 0) sources. robots.txt is honoured; one request per camera per refresh interval.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: hub.feedRunner.status) { _, _ in reload() }
        .sheet(item: Binding(get: { reviewing.map(HostBox.init) }, set: { reviewing = $0?.host })) { box in
            TermsReviewSheet(hub: hub, host: box.host,
                             sample: catalogue?.sources.first { $0.url.host == box.host.host }) {
                reviewing = nil; reload()
            }
        }
    }

    private struct HostBox: Identifiable { let host: FeedHostSummary; var id: String { host.host } }

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
    @State private var server = ""
    @State private var token = ""
    @State private var note = ""

    var body: some View {
        Form {
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


/// Shows the selected camera's current frame, refreshed no faster than the source's own interval.
struct CameraPreviewPanel: View {
    @ObservedObject var hub: HubController
    let source: PublicFeedSource?
    @State private var image: NSImage?
    @State private var fetchedAt: Date?
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let source {
                Text(source.name).font(.headline)
                Text(source.url.host ?? "").font(.caption).foregroundStyle(.secondary).monospaced()
                ZStack {
                    Rectangle().fill(.black.opacity(0.85))
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Text(message.isEmpty ? "Loading…" : message).foregroundStyle(.secondary).padding() }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                HStack {
                    if let fetchedAt { Text("Updated \(fetchedAt, format: .dateTime.hour().minute().second())").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Refresh now") { Task { await load(source) } }
                }
                if !source.mayBeAnalysed {
                    Text("Confirm this host's terms (Review terms…) to view and poll its cameras.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Select a camera to see its current frame.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .task(id: source?.id) {
            image = nil; fetchedAt = nil; message = ""
            guard let source else { return }
            while !Task.isCancelled {
                await load(source)
                try? await Task.sleep(for: .seconds(max(source.refreshInterval, 10)))
            }
        }
    }

    private func load(_ source: PublicFeedSource) async {
        do {
            let data = try await hub.feedRunner.fetchPreview(of: source)
            if let img = NSImage(data: data) { image = img; fetchedAt = Date(); message = "" }
        } catch { message = error.localizedDescription; image = nil }
    }
}
