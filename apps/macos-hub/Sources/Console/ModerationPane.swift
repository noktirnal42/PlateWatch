import SwiftUI

/// Moderator review queue. Shown only to an enrolled moderator. Mirrors the server's privacy rule: items carry unit
/// number, ~1 km area and fleet confidence, never a plate.
struct ModerationPane: View {
    var onSignOut: () -> Void
    @State private var items: [ModerationClient.Item] = []
    @State private var error: String?
    @State private var busy = false
    @State private var selection: ModerationClient.Item.ID?

    private let client = ModerationClient()
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(items.count) pending").font(.headline)
                Spacer()
                Button("Refresh") { Task { await load() } }.disabled(busy)
            }
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            if !note.isEmpty { Text(note).font(.caption).foregroundStyle(.secondary) }
            Table(items, selection: $selection) {
                TableColumn("Unit") { Text($0.unitNumber ?? "—") }
                TableColumn("Area (geohash6)") { Text($0.geohash6).monospaced() }
                TableColumn("Fleet confidence") { Text($0.fleetConfidence, format: .percent.precision(.fractionLength(0))) }
                TableColumn("Captured") { Text($0.capturedAt, format: .dateTime) }
            }
            HStack {
                Button("Approve as fleet vehicle") { Task { await decide(.approve) } }
                    .keyboardShortcut("a", modifiers: .command)
                Button("Reject", role: .destructive) { Task { await decide(.reject) } }
                    .keyboardShortcut("r", modifiers: .command)
                Spacer()
                Text("Approving publishes the sighting to the world-readable feed.").font(.caption).foregroundStyle(.secondary)
            }.disabled(selection == nil || busy)
        }
        .padding()
        .task { await load() }
    }

    private func load() async {
        guard let client else { error = ModerationClient.ClientError.notEnrolled.localizedDescription; return }
        busy = true; note = "Loading from \(client.baseURL.host ?? "server")…"
        defer { busy = false }
        do { items = try await client.queue(); error = nil; note = "Loaded \(items.count) at \(Date().formatted(date: .omitted, time: .standard))" }
        catch { self.error = error.localizedDescription; note = "" }
    }

    private func decide(_ d: ModerationClient.Decision) async {
        guard let client, let id = selection else { return }
        busy = true; defer { busy = false }
        do { try await client.decide(id, d); items.removeAll { $0.id == id }; selection = nil; error = nil }
        catch { self.error = error.localizedDescription }
    }
}
