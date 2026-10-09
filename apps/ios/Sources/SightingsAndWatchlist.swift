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

/// Watchlist management. Entries stay on this device (persisted via
/// SwiftData, never published); matching runs locally in the capture loop
/// and via silent CloudKit pushes for fleet-confirmed shareable hits.
struct WatchlistView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WatchlistItem.createdAt, order: .reverse)
    private var items: [WatchlistItem]
    @State private var newPlate = ""

    var body: some View {
        NavigationStack {
            List {
                Section("Watch a plate") {
                    HStack {
                        TextField("Plate (e.g. 1ABC234)", text: $newPlate)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                        Button("Add") {
                            let normalized = Plate.normalize(newPlate)
                            modelContext.insert(WatchlistItem(plateText: normalized))
                            try? modelContext.save()
                            newPlate = ""
                        }
                        .disabled(Plate.normalize(newPlate).count < 3)
                    }
                }
                Section("Active (\(items.count))") {
                    ForEach(items) { item in
                        Label(item.plateText ?? "re-ID anchor", systemImage: "car")
                    }
                    .onDelete { idx in
                        for i in idx { modelContext.delete(items[i]) }
                        try? modelContext.save()
                    }
                }
            }
            .navigationTitle("Watchlist")
        }
    }
}
