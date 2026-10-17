import PlateKit
import PlateSync
import SwiftData
import SwiftUI
import WatchKit

@main
struct PlateWatchWatchApp: App {
    @WKExtensionDelegateAdaptor(WatchExtensionDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView(delegate: delegate)
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { WatchPresenceCoordinator.shared.start() }
            else { WatchPresenceCoordinator.shared.stop() }
        }
    }
}

/// watchOS is intentionally camera-less: this app is the alert-and-log
/// companion. CKQuerySubscription pushes wake it when a watchlist vehicle is
/// fleet-confirmed nearby; the extension delegate plays the haptic.
struct WatchRootView: View {
    @ObservedObject var delegate: WatchExtensionDelegate

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if delegate.hits.isEmpty {
                        Text("No alerts yet")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(delegate.hits) { hit in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(hit.title)
                                Text(hit.when, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text("Recent fleet hits")
                        Spacer()
                        if delegate.unreadCount > 0 {
                            Text("\(delegate.unreadCount) new")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                NavigationLink("Quick log") {
                    QuickLogView()
                }
            }
            .navigationTitle("PlateWatch")
        }
    }
}

/// Dictation-based field note: "Black and white unit 8823 on 5th" → outbox
/// row on the watch, drained whenever the paired network path exists.
struct QuickLogView: View {
    @State private var note = ""
    @State private var saved = false
    @State private var container: ModelContainer?

    var body: some View {
        VStack(spacing: 12) {
            TextField("Say or type what you saw…", text: $note)
            Button("Log it") { save() }
                .disabled(note.trimmingCharacters(in: .whitespaces).isEmpty)
            if saved {
                Label("Queued", systemImage: "checkmark.circle")
                    .foregroundStyle(.green)
            }
        }
        .padding()
        .task {
            if container == nil {
                let schema = Schema([PendingSubmission.self])
                let config = ModelConfiguration("PlateWatchWatch", schema: schema,
                                                cloudKitDatabase: .none)
                container = try? ModelContainer(for: schema, configurations: config)
            }
        }
    }

    private func save() {
        guard let container else { return }
        let dto = SightingSubmissionDTO(
            capturedAt: Date(),
            geohash6: "",   // no GPS fix required for manual notes
            deviceIDHash: (try? DeviceIdentity.loadOrCreate().publicKeyHash) ?? "unknown",
            fleetConfidence: 0.0,   // manual note = lowest confidence tier
            vehicle: VehicleObservationDTO(vehicleClass: VehicleClass.unknown.rawValue,
                                           classConfidence: 0),
            markings: FleetMarkingsDTO(note: note.trimmingCharacters(in: .whitespaces)))
        guard let payload = try? JSONEncoder.withISODates.encode(dto) else { return }
        let context = ModelContext(container)
        context.insert(PendingSubmission(
            idempotencyKey: OutboxDrainer.idempotencyKey(for: dto),
            payloadJSON: payload))
        try? context.save()
        saved = true
        note = ""
        WKInterfaceDevice.current().play(.click)
    }
}
