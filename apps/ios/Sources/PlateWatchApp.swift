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

    init() {
        let schema = Schema([PendingSubmission.self, WatchlistItem.self])
        let config = ModelConfiguration("PlateWatch", schema: schema, cloudKitDatabase: .none)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SwiftData unavailable: \(error)")
        }
        backend = SyncBackends.makeDefault()
    }

    @AppStorage("hasOnboarded") private var hasOnboarded = false

    var body: some Scene {
        WindowGroup {
            TabView {
                CaptureView()
                    .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                SightingsListView()
                    .tabItem { Label("Sightings", systemImage: "list.bullet.rectangle") }
                WatchlistView()
                    .tabItem { Label("Watchlist", systemImage: "eye") }
                HeatmapView()
                    .tabItem { Label("Explore", systemImage: "map") }
                SettingsView()
                    .tabItem { Label("About", systemImage: "info.circle") }
            }
            .tint(Color.accentColor)
            .fullScreenCover(isPresented: Binding(get: { !hasOnboarded }, set: { _ in })) {
                OnboardingView {
                    hasOnboarded = true
                    LocationProvider.shared.authorizeIfNeeded()
                }
            }
            .task {
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
                if phase == .active {
                    Task { await drainOutbox() }
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
    static let defaultValue: any SyncBackend = SyncBackends.makeDefault()
}

public extension EnvironmentValues {
    var syncBackend: any SyncBackend {
        get { self[SyncBackendKey.self] }
        set { self[SyncBackendKey.self] = newValue }
    }
}
