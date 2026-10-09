import PlateKit
import PlateSync
import SwiftData
import SwiftUI

@main
struct PlateWatchApp: App {
    @Environment(\.scenePhase) private var scenePhase

    let modelContainer: ModelContainer
    let backend: any SyncBackend

    init() {
        let schema = Schema([PendingSubmission.self, WatchlistItem.self])
        let config = ModelConfiguration("PlateWatch", schema: schema)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SwiftData unavailable: \(error)")
        }
        backend = CloudKitBackend()
        LocationProvider.shared.authorizeIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            TabView {
                CaptureView()
                    .tabItem { Label("Capture", systemImage: "camera.viewfinder") }
                SightingsListView()
                    .tabItem { Label("Sightings", systemImage: "list.bullet.rectangle") }
                WatchlistView()
                    .tabItem { Label("Watchlist", systemImage: "eye") }
            }
            .task {
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
    static let defaultValue: any SyncBackend = CloudKitBackend()
}

public extension EnvironmentValues {
    var syncBackend: any SyncBackend {
        get { self[SyncBackendKey.self] }
        set { self[SyncBackendKey.self] = newValue }
    }
}
