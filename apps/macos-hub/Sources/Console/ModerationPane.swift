import SwiftUI

/// Moderator-only console. Queue items never contain plate text. Backend authorization remains the security boundary.
struct ModerationPane: View {
    var onSignOut: () -> Void
    @StateObject private var store = ModerationStore()
    @State private var selection: ModerationClient.Item.ID?
    @State private var takedownSelection: ModerationClient.Takedown.ID?
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Moderation section", selection: $tab) {
                    Text("Sightings (\(store.items.count))").tag(0)
                    Text("Takedown requests (\(store.takedowns.count))").tag(1)
                    Text("Audit log (\(store.audit.count))").tag(2)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 620)
                Spacer()
                if store.busy { ProgressView().controlSize(.small).accessibilityLabel("Refreshing moderation data") }
                Button("Refresh", systemImage: "arrow.clockwise") { Task { await store.refresh() } }.disabled(store.busy)
            }
            if let server = ModeratorAccess.serverURL {
                Text("Moderation server: \(server.absoluteString) · REST, separate from CloudKit")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            Label("Server health: \(store.serverStatus)",
                  systemImage: store.serverStatus == "Reachable" ? "checkmark.circle.fill" : "network.slash")
                .font(.caption)
                .foregroundStyle(store.serverStatus == "Reachable" ? Color.green : Color.orange)
                .accessibilityElement(children: .combine)
            if let error = activeError { Label(error, systemImage: "exclamationmark.triangle").foregroundStyle(.red).textSelection(.enabled) }
            if let actionError = store.actionError { Text(actionError).foregroundStyle(.red) }
            if tab == 2 { auditView } else if tab == 1 { takedownView } else { sightingsView }
            if let last = store.lastLoadedAt {
                Text("Last refresh: \(last.formatted(date: .omitted, time: .standard))").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .task { await store.connect() }
    }

    private var activeError: String? {
        switch tab { case 1: store.takedownError; case 2: store.auditError; default: store.queueError }
    }

    private var auditView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(store.audit) {
                TableColumn("When") { row in
                    if let date = row.createdAt { Text(date, format: .dateTime) } else { Text("Not recorded").foregroundStyle(.secondary) }
                }
                TableColumn("Action") { Text($0.action).monospaced() }
                TableColumn("Target") { Text($0.target?.prefix(8).lowercased() ?? "—").monospaced() }
                TableColumn("Detail") { Text($0.detail ?? "") }
            }
            .overlay {
                if store.audit.isEmpty && !store.busy && store.auditError == nil {
                    ContentUnavailableView("No audit entries returned", systemImage: "list.clipboard", description: Text("Refresh to check for new moderator actions."))
                }
            }
            Text("Newest 200 audit entries. Actions and target IDs only; sighting content is excluded. A refresh error leaves the last loaded rows visible.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var takedownView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Table(store.takedowns, selection: $takedownSelection) {
                TableColumn("Received") { row in
                    if let date = row.createdAt { Text(date, format: .dateTime) } else { Text("Not recorded") }
                }
                TableColumn("Sighting") { Text($0.sightingID?.uuidString.prefix(8).lowercased() ?? "—").monospaced() }
                TableColumn("Reason") { Text($0.reason).lineLimit(2) }
                TableColumn("Contact") { Text($0.contact ?? "—") }
            }
            HStack {
                Button("Hide sighting permanently", role: .destructive) { Task { await resolve(hide: true) } }
                Button("Dismiss request") { Task { await resolve(hide: false) } }
                Spacer()
                Text("Hide removes the sighting from every public surface.").font(.caption).foregroundStyle(.secondary)
            }.disabled(takedownSelection == nil || store.busy)
        }
    }

    private var sightingsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(store.queueError == nil ? "\(store.items.count) pending" : "Queue unavailable · \(store.items.count) last loaded").font(.headline)
            Table(store.items, selection: $selection) {
                TableColumn("Unit") { Text($0.unitNumber ?? "—") }
                TableColumn("Area (geohash6)") { Text($0.geohash6).monospaced() }
                TableColumn("Fleet confidence") { Text($0.fleetConfidence, format: .percent.precision(.fractionLength(0))) }
                TableColumn("Captured") { Text($0.capturedAt, format: .dateTime) }
            }
            .overlay {
                if store.items.isEmpty && !store.busy {
                    if store.queueError != nil {
                        ContentUnavailableView("Moderation server unavailable", systemImage: "network.slash",
                            description: Text("Start the configured reference server, then Refresh. CloudKit does not serve this REST queue."))
                    } else {
                        ContentUnavailableView("No pending server submissions", systemImage: "checkmark.shield",
                            description: Text("Items in local Review have not been delivered to this queue."))
                    }
                }
            }
            HStack {
                Button("Approve as fleet vehicle") { Task { await decide(.approve) } }.keyboardShortcut("a", modifiers: .command)
                Button("Reject", role: .destructive) { Task { await decide(.reject) } }.keyboardShortcut("r", modifiers: .command)
                Spacer()
                Text("Approving publishes the sighting to the world-readable feed.").font(.caption).foregroundStyle(.secondary)
            }.disabled(selection == nil || store.busy)
        }
    }

    private func resolve(hide: Bool) async {
        guard let id = takedownSelection else { return }
        if await store.resolve(id, hide: hide) { takedownSelection = nil }
    }
    private func decide(_ decision: ModerationClient.Decision) async {
        guard let id = selection else { return }
        if await store.decide(id, decision: decision) { selection = nil }
    }
}
