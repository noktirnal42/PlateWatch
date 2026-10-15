import AccountabilityKit
import PlateKit
import PlateSync
import SwiftData
import SwiftUI

/// Local outbox review: what this Hub has recorded and queued for sync. Discarding removes only the local copy.
/// Each identified vehicle carries its evidence crop when one could be captured (`SightingSubmissionDTO.cropJPEGBase64`).
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
        let agencyKey: String?
        let confidence: Double
        let retries: Int
        let error: String
        let thumbnail: NSImage?
    }

    private var table: [Row] {
        rows.map { r in
            let dto = try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: r.payloadJSON)
            return Row(id: r.persistentModelID, key: r.idempotencyKey, captured: dto?.capturedAt ?? r.createdAt,
                       area: dto?.geohash6 ?? "?", unit: dto?.markings?.unitNumber ?? "—",
                       agency: dto?.markings?.agencyText ?? dto?.identity?.agency?.agencyKey ?? "unresolved",
                       agencyKey: dto?.identity?.agency?.agencyKey,
                       confidence: dto?.fleetConfidence ?? 0, retries: r.retryCount, error: r.lastError ?? "",
                       thumbnail: dto?.cropJPEGBase64.flatMap { Data(base64Encoded: $0) }.flatMap(NSImage.init(data:)))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("\(rows.count) queued").font(.headline)
                Spacer()
                Button("Discard selected (local only)") {
                    if let id = selection, let row = rows.first(where: { $0.persistentModelID == id }) {
                        context.delete(row); try? context.save(); selection = nil
                    }
                }
                .buttonStyle(.bordered)
                .disabled(selection == nil)
            }
            Table(table, selection: $selection) {
                TableColumn("Image") { EvidenceThumbnail(image: $0.thumbnail) }.width(min: 72, ideal: 80)
                TableColumn("Captured") { Text($0.captured, format: .dateTime) }
                TableColumn("Agency") { Text($0.agency) }
                TableColumn("Unit") { Text($0.unit) }
                TableColumn("Area") { Text($0.area).monospaced() }
                TableColumn("Fleet") { Text($0.confidence, format: .percent.precision(.fractionLength(0))) }
                TableColumn("Retries") { Text("\($0.retries)") }
                TableColumn("Last error") { Text($0.error).foregroundStyle(.secondary) }
            }
            if let row = table.first(where: { $0.id == selection }) { UnitRecordsStrip(unit: row.unit, agencyKey: row.agencyKey) }
            Text("Evidence crops ride in the local queue and are view-only here; the backend keeps the crop hash, never image bytes. Discarding here does not retract anything already delivered.")
                .font(.caption).foregroundStyle(.secondary)
        }.padding()
    }
}

/// The evidence image at thumbnail size; click to inspect at full resolution.
private struct EvidenceThumbnail: View {
    let image: NSImage?
    @State private var enlarged = false

    var body: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                .contentShape(RoundedRectangle(cornerRadius: 5))
                .onTapGesture { enlarged = true }
                .help("Click to view full size")
                .sheet(isPresented: $enlarged) { EvidenceViewer(image: image) }
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.tertiary)
                .frame(width: 64, height: 40)
                .help("No evidence image was captured for this sighting")
        }
    }
}

/// Full-size evidence view at native resolution, scrollable if larger than the window.
private struct EvidenceViewer: View {
    let image: NSImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 10) {
            ScrollView([.horizontal, .vertical]) {
                Image(nsImage: image)
                    .interpolation(.high)
                    .padding(8)
            }
            HStack {
                Text("Evidence crop · \(Int(image.size.width)) × \(Int(image.size.height)) px")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 520, minHeight: 400)
    }
}


/// Cited public records for the selected vehicle's **unit and agency only**. It is given no place, time or camera, so it
/// cannot show where anyone was; it shows moderator-confirmed unit↔person links and cited records, never inferences, and
/// stays empty unless the agency was recognised (unit numbers repeat across agencies).
private struct UnitRecordsStrip: View {
    let unit: String
    let agencyKey: String?
    @State private var workspace = RecordsWorkspace.shared

    var body: some View {
        let result = workspace.unitIndex.records(forUnit: unit, agencyKey: agencyKey)
        if !result.isEmpty {
            GroupBox("Cited public records for unit \(unit)") {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(result.agencyRecords) { r in recordLine(r, prefix: "Agency") }
                    ForEach(result.officials, id: \.link.id) { o in
                        Text("\(o.profile.name) — \(o.profile.role.isEmpty ? "public official" : o.profile.role) (confirmed unit link, cited)").font(.caption.bold())
                        ForEach(o.records) { r in recordLine(r, prefix: "Record") }
                    }
                    Text("Allegation is not fact: each line is the source's own wording and status. Records only — no location or timeline is attached.")
                        .font(.caption2).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, alignment: .leading).padding(4)
            }
        }
    }

    private func recordLine(_ r: IncidentRecord, prefix: String) -> some View {
        HStack(spacing: 6) {
            Text("\(prefix): \(r.kind.rawValue) · \(r.reference)\(r.status.isEmpty ? "" : " · \(r.status)")").font(.caption)
            if let url = r.citations.first?.url { Link("source", destination: url).font(.caption) }
        }
    }
}
