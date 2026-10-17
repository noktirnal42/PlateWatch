import PlateKit
import PlateSync
import SwiftUI
import SwiftData

/// First-run explanation of what PlateWatch is — and is not. The legal and
/// ethical model is the product's differentiator, so it comes before any
/// permission prompt.
struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    HStack {
                        Image("BrandIcon").resizable().scaledToFit()
                            .frame(width: 88, height: 88)
                            .clipShape(.rect(cornerRadius: 20))
                            .accessibilityHidden(true)
                        Spacer()
                        Text("PRE-ALPHA").font(.caption.weight(.bold)).tracking(2)
                            .foregroundStyle(PWStyle.fleet)
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Watch the public fleet.")
                            .font(.largeTitle.weight(.bold))
                        Text("PlateWatch").font(.headline).foregroundStyle(PWStyle.fleet)
                        Text("Hold taxpayer-funded vehicles accountable — police, fire, transit, public works and government fleets.")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    principle("lock.shield.fill", "On-device analysis",
                              "Camera frames are read on your iPhone. Raw video stays on your device.")
                    principle("building.columns.fill", "Fleet vehicles only",
                              "Private-citizen plates are dropped before anything is saved or shared.")
                    principle("doc.text.magnifyingglass", "Public records, with sources",
                              "Agency readings show their evidence. Public-record enrichment must always carry a citation.")
                    principle("hand.raised.fill", "Your location stays coarse",
                              "Sightings are bucketed to about 1 km unless a vehicle is fleet-confirmed.")
                    Button(action: onContinue) {
                        Text("Get started")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(PWStyle.fleet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.top, 8)
                    Text("You’ll be asked for camera and location access next. Both are optional — you can import photos instead.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(24)
                .frame(maxWidth: 560)
                .frame(maxWidth: .infinity)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private func principle(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(PWStyle.fleet)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// About + diagnostics: which backend is live, what analyzers are active,
/// and where the rules live. Nothing here is a developer string.
struct SettingsView: View {
    @Environment(\.syncBackend) private var backend
    @Environment(\.modelContext) private var modelContext
    @Query private var queued: [PendingSubmission]
    @Query private var watchlist: [WatchlistItem]
    @State private var confirmClear = false
    @State private var errorText: String?
    @State private var connectionStatus = "Not checked"
    @State private var checkingConnection = false
    @AppStorage("presenceEnabled") private var presenceEnabled = false

    private var backendName: String {
        backend is CloudKitBackend ? "iCloud (CloudKit public database)" : "Self-hosted server"
    }
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(alignment: .top, spacing: 16) {
                        Image("BrandIcon").resizable().scaledToFit()
                            .frame(width: 76, height: 76).clipShape(.rect(cornerRadius: 18))
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("PlateWatch").font(.title2.weight(.bold))
                            Text("Public fleets. Public accountability.").font(.subheadline).foregroundStyle(.secondary)
                            Text("PRE-ALPHA · \(version)").font(.caption.monospaced()).foregroundStyle(PWStyle.fleetText)
                        }
                    }.padding(.vertical, 8)
                }
                Section("Analysis & delivery") {
                    LabeledContent("Shared database") { Text(backendName).multilineTextAlignment(.trailing) }
                    LabeledContent("Connection") {
                        HStack(spacing: 6) {
                            Image(systemName: connectionIcon)
                                .foregroundStyle(connectionStatus.localizedCaseInsensitiveContains("Connected") ? .green : .secondary)
                            Text(connectionStatus).multilineTextAlignment(.trailing)
                        }
                    }
                    Button(checkingConnection ? "Checking…" : "Check connection", systemImage: "arrow.clockwise") {
                        Task { await checkConnection() }
                    }
                    .disabled(checkingConnection)
                    LabeledContent("Analysis") {
                        Text(PassiveCaptureStatus.shared.modelStatus == "baseline vision"
                             ? "Apple Vision (on-device)" : PassiveCaptureStatus.shared.modelStatus)
                            .multilineTextAlignment(.trailing)
                    }
                    NavigationLink {
                        AgencyDirectoryView()
                    } label: {
                        Label("Agency report cards", systemImage: "building.columns")
                    }
                }
                Section("Live presence") {
                    Toggle("Share active processing count", isOn: $presenceEnabled)
                        .onChange(of: presenceEnabled) { _, enabled in
                            if enabled { PresenceCoordinator.shared.start() }
                            else { PresenceCoordinator.shared.stop() }
                        }
                    Text("Optional and off by default. Shares only an anonymous expiring count while this device is actively scanning; no plates, frames, names, or history are sent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section {
                    LabeledContent("Queued observations", value: String(queued.count))
                    LabeledContent("Local watchlist", value: String(watchlist.count))
                    Button("Clear local queue & watchlist", systemImage: "trash", role: .destructive) { confirmClear = true }
                } header: { Text("On this device") } footer: {
                    Text("Clears queued observations and local watchlist entries. Already received, published or in-flight submissions require backend removal and are not deleted by this action.")
                }
                Section("Principles") {
                    Label("Fleet vehicles only", systemImage: "building.columns")
                    Label("On-device analysis, no tracking", systemImage: "lock.shield")
                    Label("Public records only, always cited", systemImage: "doc.text.magnifyingglass")
                }
                Section("Learn more") {
                    Link(destination: URL(string: "https://noktirnal42.github.io/PlateWatch/")!) {
                        Label("Project website", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://github.com/noktirnal42/PlateWatch/blob/main/docs/LEGAL-ETHICS.md")!) {
                        Label("Legal & ethics", systemImage: "scale.3d")
                    }
                    Link(destination: URL(string: "https://github.com/noktirnal42/PlateWatch")!) {
                        Label("Source code (AGPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Section {
                    LabeledContent("Version") { Text(version) }
                } footer: {
                    Text("PlateWatch is pre-alpha. Detection quality is still being tuned.")
                }
            }
            .safeAreaInset(edge: .top) { PreviewBanner() }
            .navigationTitle("About")
            .task { await checkConnection() }
            .confirmationDialog("Clear local data?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Clear queue & watchlist", role: .destructive) { clearLocalData() }
            } message: { Text("This removes \(queued.count) queued observations and \(watchlist.count) watchlist entries from this device. Backend records and transfers already in progress are unaffected.") }
            .alert("Could not clear local data", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private var connectionIcon: String {
        if connectionStatus == "Not checked" { return "questionmark.circle" }
        if connectionStatus == "Checking…" { return "hourglass" }
        return connectionStatus.localizedCaseInsensitiveContains("Connected") ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
    }

    @MainActor
    private func checkConnection() async {
        guard !checkingConnection else { return }
        checkingConnection = true
        connectionStatus = "Checking…"
        connectionStatus = await BackendDiagnostics.status(for: backend)
        checkingConnection = false
    }

    private func clearLocalData() {
        for row in queued { modelContext.delete(row) }
        for row in watchlist { modelContext.delete(row) }
        do {
            try modelContext.save()
            if !PreviewFixtures.isEnabled { UserDefaults.standard.removeObject(forKey: "watchlistPlates") }
        } catch { modelContext.rollback(); errorText = error.localizedDescription }
    }

}
