import PlateKit
import PlateSync
import SwiftData
import SwiftUI

/// Local outbox review: what this Hub has recorded and queued for sync. Discarding removes only the local copy.
struct ReviewPane: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \PendingSubmission.createdAt, order: .reverse) private var rows: [PendingSubmission]
    @State private var selection: PersistentIdentifier?

    private struct Row: Identifiable {
        let id: PersistentIdentifier
        let key: String
        let captured: Date
        let area: String
        let unit: String
        let agency: String
        let confidence: Double
        let retries: Int
        let error: String
    }

    private var table: [Row] {
        rows.map { r in
            let dto = try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: r.payloadJSON)
            return Row(id: r.persistentModelID, key: r.idempotencyKey, captured: dto?.capturedAt ?? r.createdAt,
                       area: dto?.geohash6 ?? "?", unit: dto?.markings?.unitNumber ?? "—",
                       agency: dto?.markings?.agencyText ?? dto?.identity?.agency?.agencyKey ?? "unresolved",
                       confidence: dto?.fleetConfidence ?? 0, retries: r.retryCount, error: r.lastError ?? "")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(rows.count) queued").font(.headline)
                Spacer()
                Button("Discard selected (local only)", role: .destructive) {
                    if let id = selection, let row = rows.first(where: { $0.persistentModelID == id }) {
                        context.delete(row); try? context.save(); selection = nil
                    }
                }.disabled(selection == nil)
            }
            Table(table, selection: $selection) {
                TableColumn("Captured") { Text($0.captured, format: .dateTime) }
                TableColumn("Agency") { Text($0.agency) }
                TableColumn("Unit") { Text($0.unit) }
                TableColumn("Area") { Text($0.area).monospaced() }
                TableColumn("Fleet") { Text($0.confidence, format: .percent.precision(.fractionLength(0))) }
                TableColumn("Retries") { Text("\($0.retries)") }
                TableColumn("Last error") { Text($0.error).foregroundStyle(.secondary) }
            }
            Text("Queued sightings sync to the backend when it is reachable. Discarding here does not retract anything already delivered.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}
