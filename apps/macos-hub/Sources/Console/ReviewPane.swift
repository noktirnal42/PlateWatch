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
