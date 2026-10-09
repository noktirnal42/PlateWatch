import PlateKit
import PlateSync
import SwiftData
import SwiftUI

/// Review queue: what the device has seen, and what state each sighting is
/// in. This is intentionally the only per-sighting list view — the shared
/// database view is at agency level, not individual-movement level.
struct SightingsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \PendingSubmission.createdAt, order: .reverse)
    private var outbox: [PendingSubmission]

    var body: some View {
        NavigationStack {
            List {
                if outbox.isEmpty {
                    ContentUnavailableView(
                        "No queued sightings",
                        systemImage: "tray",
                        description: Text("Fleet detections appear here before sync. Nothing raw ever leaves the device."))
                }
                ForEach(outbox) { row in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(row.createdAt.formatted(date: .abbreviated, time: .shortened))
                            .font(.headline)
                        Text("pending sync · retries \(row.retryCount)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in
                    for i in idx { modelContext.delete(outbox[i]) }
                }
            }
            .navigationTitle("Sightings")
        }
    }
}

/// Watchlist management. Entries stay on this device (never published);
/// matching happens locally + via silent CloudKit pushes.
struct WatchlistView: View {
    @State private var newPlate = ""
    @State private var entries: [WatchlistEntry] = []

    var body: some View {
        NavigationStack {
            List {
                Section("Watch a plate") {
                    HStack {
                        TextField("Plate (e.g. 1ABC234)", text: $newPlate)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Add") {
                            let entry = WatchlistEntry(plateText: Plate.normalize(newPlate))
                            entries.append(entry)
                            newPlate = ""
                        }
                        .disabled(Plate.normalize(newPlate).count < 3)
                    }
                }
                Section("Active (\(entries.count))") {
                    ForEach(entries) { entry in
                        Label(entry.plateText ?? "re-ID anchor", systemImage: "car")
                    }
                    .onDelete { idx in entries.remove(atOffsets: idx) }
                }
            }
            .navigationTitle("Watchlist")
        }
    }
}
