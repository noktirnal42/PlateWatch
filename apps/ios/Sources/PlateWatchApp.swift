import PlateKit
import PlateSync
import SwiftData
import SwiftUI

@main
struct PlateWatchApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer
    let backend: any SyncBackend
    @State private var previewOnboarded = false
    @State private var selectedTab = PreviewFixtures.initialTab

    init() {
        let schema = Schema([PendingSubmission.self, ReceivedSubmissionReceipt.self, WatchlistItem.self])
        let config = ModelConfiguration("PlateWatch", schema: schema, isStoredInMemoryOnly: PreviewFixtures.isEnabled, cloudKitDatabase: .none)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SwiftData unavailable: \(error)")
        }
        backend = AppSyncConfiguration.makeBackend()
        WatchlistConnectivity.shared.start()
        PreviewFixtures.populate(modelContainer)
        #if DEBUG
        SelfTest.runIfRequested()
        #endif
    }

    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some Scene {
        WindowGroup {
            TabView(selection: $selectedTab) {
                CaptureView()
                    .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                    .tag(0)
                SightingsListView()
                    .tabItem { Label("Sightings", systemImage: "list.bullet.rectangle") }
                    .tag(1)
                WatchlistView()
                    .tabItem { Label("Watchlist", systemImage: "eye") }
                    .tag(2)
                HeatmapView()
                    .tabItem { Label("Explore", systemImage: "map") }
                    .tag(3)
                SettingsView()
                    .tabItem { Label("About", systemImage: "info.circle") }
                    .tag(4)
            }
            .modifier(PreviewAppearance())
            .tint(PWStyle.fleetText)
            .fullScreenCover(isPresented: Binding(get: { PreviewFixtures.isEnabled ? ProcessInfo.processInfo.arguments.contains("-PWPreviewOnboarding") && !previewOnboarded : !hasOnboarded }, set: { _ in })) {
                OnboardingView {
                    if PreviewFixtures.isEnabled { previewOnboarded = true }
                    else {
                        hasOnboarded = true
                        LocationProvider.shared.authorizeIfNeeded()
                    }
                }
            }
            .task {
                guard !PreviewFixtures.isEnabled else { return }
                if hasOnboarded { LocationProvider.shared.authorizeIfNeeded() }
                try? await backend.ensureWatchlistSubscription()
                // Steady drain loop: outbox empties opportunistically, never
                // blocking the capture path.
                while !Task.isCancelled {
                    await drainOutbox()
                    try? await Task.sleep(for: .seconds(30))
                }
            }
            .onChange(of: scenePhase) { _, phase in
                guard !PreviewFixtures.isEnabled else { return }
                if phase == .active {
                    Task { await drainOutbox() }
                    PresenceCoordinator.shared.start()
                } else if phase == .background {
                    PresenceCoordinator.shared.stop()
                }
            }
        }
        .modelContainer(modelContainer)
        .environment(\.syncBackend, backend)
    }

    private func drainOutbox() async {
        let context = ModelContext(modelContainer)
        await OutboxDrainer(backend: backend).drain(context: context)
    }
}

private struct SyncBackendKey: EnvironmentKey {
    static let defaultValue: any SyncBackend = AppSyncConfiguration.makeBackend()
}

public extension EnvironmentValues {
    var syncBackend: any SyncBackend {
        get { self[SyncBackendKey.self] }
        set { self[SyncBackendKey.self] = newValue }
    }
}

/// Unsigned simulator builds cannot construct an entitled CloudKit container.
/// Keep this app boundary explicit; signed physical-device builds use PlateSync.
enum AppSyncConfiguration {
    static func makeBackend() -> any SyncBackend {
        let settings = SyncSettings.load()
        #if targetEnvironment(simulator)
        let configured = ProcessInfo.processInfo.environment["PLATEWATCH_MIRROR_URL"]
        let fallback = SyncBackends.mirrorURL(override: nil, stored: settings.mirrorURL)
        let url = configured.flatMap(URL.init(string:)).flatMap {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host != nil ? $0 : nil
        } ?? fallback
        return RESTBackend(baseURL: url)
        #else
        return SyncBackends.makeConfigured(settings: settings)
        #endif
    }
}
