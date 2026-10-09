import PlateKit
import PlateSync
import SwiftData
import SwiftUI

@main
struct PlateWatchApp: App {
    let modelContainer: ModelContainer
    let backend: any SyncBackend

    init() {
        let schema = Schema([PendingSubmission.self])
        let config = ModelConfiguration("PlateWatch", schema: schema)
        do {
            modelContainer = try ModelContainer(for: schema, configurations: config)
        } catch {
            fatalError("SwiftData unavailable: \(error)")
        }
        backend = CloudKitBackend()
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
            }
        }
        .modelContainer(modelContainer)
        .environment(\.syncBackend, backend)
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
