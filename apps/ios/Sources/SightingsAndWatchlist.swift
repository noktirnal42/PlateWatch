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
                    PWEmptyState(
                        title: "No sightings yet",
                        message: "When PlateWatch recognizes a government vehicle it appears here until it syncs. Point the camera at a patrol car, or import a photo from Capture.",
                        systemImage: "car.side.fill")
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(outbox) { row in
                            SightingRow(row: row)
                        }
                        .onDelete { idx in
                            for i in idx { modelContext.delete(outbox[i]) }
                        }
                    } footer: {
                        Text("Swipe a row to discard it before it syncs. “Needs attention” means the shared database could not be reached after several tries — records stay safely on this device and retry automatically.")
                    }
                }
            }
            .navigationTitle("Sightings")
        }
    }
}

private struct SightingRow: View {
    let row: PendingSubmission

    /// What the detection actually was, decoded from the queued payload.
    private var submission: SightingSubmissionDTO? {
        try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: row.payloadJSON)
    }

    private var title: String {
        let m = submission?.markings
        let parts = [m?.serviceClassText?.capitalized,
                     m?.unitNumber.map { "Unit \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "Government vehicle" : parts.joined(separator: " · ")
    }

    private var subtitle: String? {
        guard let agency = submission?.markings?.agencyText,
              agency.caseInsensitiveCompare(submission?.markings?.serviceClassText ?? "") != .orderedSame
        else { return nil }
        return agency.capitalized
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.side.fill")
                .font(.title3)
                .foregroundStyle(PWStyle.fleet)
                .frame(width: 36, height: 36)
                .background(PWStyle.fleet.opacity(0.15), in: .circle)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                if let subtitle {
                    Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                HStack(spacing: 8) {
                    if let plate = submission?.plate?.text { PlateBadge(text: plate, compact: true) }
                    Text(row.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                        .font(.caption).foregroundStyle(.secondary)
                }
                SyncStatusPill(retryCount: row.retryCount)
            }
            Spacer(minLength: 0)
            Image(systemName: "lock.fill")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .accessibilityLabel("Stored on this device")
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
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

    private var normalized: String { Plate.normalize(newPlate) }
    private var canAdd: Bool { normalized.count >= 3 }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        TextField("Plate, e.g. 1ABC234", text: $newPlate)
                            .textInputAutocapitalization(.characters)
                            .autocorrectionDisabled()
                            .font(.body.monospaced())
                            .submitLabel(.done)
                            .onSubmit(add)
                        Button("Add", action: add)
                            .buttonStyle(.borderedProminent)
                            .disabled(!canAdd)
                    }
                } header: {
                    Text("Watch a plate")
                } footer: {
                    Text("Matches are checked on this device and entries are never published. Allow notifications to be alerted when a watched plate is recorded.")
                }

                Section("Active (\(items.count))") {
                    if items.isEmpty {
                        Text("No plates on watch yet.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack {
                            if let plate = item.plateText {
                                PlateBadge(text: plate)
                            } else {
                                Label("Vehicle re-ID anchor", systemImage: "scope")
                            }
                            Spacer()
                            if item.notifyEnabled {
                                Image(systemName: "bell.fill")
                                    .foregroundStyle(PWStyle.fleet)
                                    .accessibilityLabel("Notifications on")
                            }
                        }
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

    private func add() {
        guard canAdd else { return }
        modelContext.insert(WatchlistItem(plateText: normalized))
        try? modelContext.save()
        newPlate = ""
        NotificationPermission.requestIfNeeded() // alerts need it; ask now, in context
        // Mirror to standard defaults — the watch extension reads its
        // lightweight copy from there for its push→haptic path.
        var mirrored = UserDefaults.standard.stringArray(forKey: "watchlistPlates") ?? []
        if !mirrored.contains(normalized) {
            mirrored.append(normalized)
            UserDefaults.standard.set(mirrored, forKey: "watchlistPlates")
        }
    }
}
