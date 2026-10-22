import PlateKit
import PlateSync
import Combine
import SwiftData
import SwiftUI
import WatchKit

@main
struct PlateWatchWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchExtensionDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            WatchRootView(delegate: delegate)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { WatchPresenceCoordinator.shared.start() }
            else { WatchPresenceCoordinator.shared.stop() }
        }
    }
}

/// Phosphor glow shared with the iPhone app: green by default; the phone relays its Green/Amber choice (`phosphor` key).
enum WatchPhosphor {
    static let defaultsKey = "pwPhosphor"
    static var isAmber: Bool { UserDefaults.standard.string(forKey: defaultsKey) == "amber" }
    static var accent: Color { isAmber ? Color(red: 1, green: 0.69, blue: 0) : Color(red: 0.24, green: 1, blue: 0.53) }
}

/// watchOS is intentionally camera-less: this app is the alert-and-log
/// companion. CKQuerySubscription pushes wake it when a watchlist vehicle is
/// fleet-confirmed nearby; the extension delegate plays the haptic.
struct WatchRootView: View {
    @ObservedObject var delegate: WatchExtensionDelegate

    var body: some View {
        NavigationStack {
            List {
                Section { WatchStatsView() } header: { Text("LIVE STATS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(WatchPhosphor.accent) }
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
                            .accessibilityElement(children: .combine)
                            .accessibilityLabel(hit.title)
                            .accessibilityValue("Received \(hit.when, style: .relative)")
                        }
                    }
                } header: {
                    HStack {
                        Text("RECENT FLEET HITS").font(.system(size: 10, weight: .semibold, design: .monospaced)).tracking(1.2).foregroundStyle(WatchPhosphor.accent)
                        Spacer()
                        if delegate.unreadCount > 0 {
                        Text("\(delegate.unreadCount) new")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                            .accessibilityLabel("\(delegate.unreadCount) unread fleet hits")
                        }
                    }
                }
                NavigationLink("Quick log") {
                    QuickLogView()
                }
            }
            .navigationTitle("PlateWatch")
        }
        .tint(WatchPhosphor.accent)
        .scrollContentBackground(.hidden)
        .background(Color.black)
    }
}

private struct WatchStatsView: View {
    @State private var stats = WatchComplicationStore.liveStats()
    @State private var isRefreshing = false
    @Environment(\.scenePhase) private var scenePhase
    private let refreshTimer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            statRow("Fleet hits today", value: stats.fleetHitsToday.map(String.init) ?? "—", icon: "car.fill")
            statRow("Active sessions", value: stats.activeSessions.map(String.init) ?? "—", icon: "person.2.fill")
            statRow("Live processors", value: stats.activeProcessors.map(String.init) ?? "—", icon: "wave.3.right")
            statRow("Frames analysed", value: stats.framesAnalyzed.map(String.init) ?? "—", icon: "viewfinder")
            statRow("Public feed frames", value: stats.publicFeedFrames.map(String.init) ?? "—", icon: "antenna.radiowaves.left.and.right")
            statRow("Skipped while busy", value: stats.skippedWhileBusy.map(String.init) ?? "—", icon: "pause.circle")
            statRow("Outbox pending", value: stats.outboxPending.map(String.init) ?? "—", icon: "tray.and.arrow.up")
            Button {
                guard !isRefreshing else { return }
                isRefreshing = true
                Task {
                    await WatchPresenceCoordinator.shared.refreshNow()
                    refresh()
                    isRefreshing = false
                }
            } label: {
                Label(isRefreshing ? "Refreshing…" : "Refresh live stats",
                      systemImage: isRefreshing ? "arrow.triangle.2.circlepath" : "arrow.clockwise")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
            .disabled(isRefreshing)
            .accessibilityHint("Requests the latest aggregate counters from the Hub")
            HStack(spacing: 5) {
                Circle()
                    .fill(freshnessColor)
                    .frame(width: 6, height: 6)
                Text(freshnessLabel)
            }
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("watch-live-stats")
        .accessibilityLabel("Hub live stats")
        .accessibilityValue(accessibilitySummary)
        .onReceive(refreshTimer) { _ in refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { refresh() }
        }
    }

    private func refresh() {
        stats = WatchComplicationStore.liveStats()
    }

    private var accessibilitySummary: String {
        let values = [
            "Fleet hits today \(stats.fleetHitsToday.map(String.init) ?? "unavailable")",
            "Active sessions \(stats.activeSessions.map(String.init) ?? "unavailable")",
            "Live processors \(stats.activeProcessors.map(String.init) ?? "unavailable")",
            "Frames analysed \(stats.framesAnalyzed.map(String.init) ?? "unavailable")",
            "Public feed frames \(stats.publicFeedFrames.map(String.init) ?? "unavailable")",
            "Skipped while busy \(stats.skippedWhileBusy.map(String.init) ?? "unavailable")",
            "Outbox pending \(stats.outboxPending.map(String.init) ?? "unavailable")"
        ]
        return values.joined(separator: ", ")
    }

    private func statRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon).frame(width: 16).foregroundStyle(WatchPhosphor.accent)
            Text(title).font(.caption)
            Spacer(minLength: 4)
            Text(value).font(.headline.monospacedDigit())
        }
    }

    private var freshnessLabel: String {
        guard let updatedAt = stats.updatedAt else { return "Waiting for Hub stats" }
        let age = max(0, Date.now.timeIntervalSince(updatedAt))
        let time = DateFormatter.localizedString(from: updatedAt, dateStyle: .none, timeStyle: .short)
        if age > 90 { return "Hub stats stale · updated \(time)" }
        return "Live · updated \(time)"
    }

    private var freshnessColor: Color {
        guard let updatedAt = stats.updatedAt else { return .secondary }
        return Date.now.timeIntervalSince(updatedAt) > 90 ? .orange : WatchPhosphor.accent
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
                .accessibilityLabel("Field note")
                .accessibilityHint("Describe a public fleet vehicle or event")
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
