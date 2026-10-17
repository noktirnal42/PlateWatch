import AccountabilityKit
import PlateKit
import PlateSync
import SwiftData
import SwiftUI

/// Local outbox review: what this Hub has recorded and queued for sync. Discarding removes only the local copy.
/// Each identified vehicle carries its evidence crop when one could be captured (`SightingSubmissionDTO.cropJPEGBase64`).
@MainActor
protocol ReviewHubProviding {
    var syncStatus: String { get }
    var lastReceiptSummary: String { get }
    func syncPending() async
    func recoverDeliveredReceipts() async
    func sendCloudKitHistoryToModeration() async
}

struct ReviewPane: View {
    let hub: (any ReviewHubProviding)?
    init(hub: (any ReviewHubProviding)? = nil, onQueueChange: @escaping () -> Void = {}) {
        self.hub = hub
        self.onQueueChange = onQueueChange
    }
    var onQueueChange: () -> Void = {}
    @Environment(\.modelContext) private var context
    @Query(sort: \PendingSubmission.createdAt, order: .reverse) private var rows: [PendingSubmission]
    @Query(sort: \ReceivedSubmissionReceipt.receivedAt, order: .reverse) private var receipts: [ReceivedSubmissionReceipt]
    @State private var selection: Set<PersistentIdentifier> = []
    @State private var discardError = ""
    @State private var showDeliveryHistory = true
    @State private var recoveringReceipts = false
    @State private var sendingCloudKit = false

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
        let confirmed: Bool
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
                       confirmed: dto?.userConfirmed == true,
                       thumbnail: dto.flatMap { EvidenceArchive.current.resolve(base64: $0.cropJPEGBase64, hash: $0.cropHashSHA256) }.flatMap(NSImage.init(data:)))
        }
    }

    private var evidenceCount: Int { table.reduce(into: 0) { count, row in if row.thumbnail != nil { count += 1 } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("\(rows.count) queued", systemImage: "tray.full")
                    .font(.headline)
                Text("· \(evidenceCount) with evidence")
                    .font(.caption)
                    .foregroundStyle(evidenceCount == rows.count ? Color.secondary : Color.orange)
                Spacer()
                if !receipts.isEmpty {
                    Text("\(receipts.count) delivered receipts")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("Local acknowledgement history retained after delivery")
                }
                Text("\(selection.count) selected").font(.caption).foregroundStyle(.secondary)
                Button("Select all") { selection = Set(rows.map(\.persistentModelID)) }.disabled(rows.isEmpty).accessibilityLabel("Select all queued sightings")
                Button("Clear selection") { selection.removeAll() }.disabled(selection.isEmpty)
                Button("Confirm selected", systemImage: "checkmark.seal") {
                    do { try ReviewQueue.confirm(selection, context: context); onQueueChange(); selection.removeAll(); discardError = "" }
                    catch { discardError = "Could not confirm selected items: \(error.localizedDescription)" }
                }
                .disabled(selection.isEmpty)
                .help("Mark selected evidence as reviewed before backend moderation")
                Button("Reject selected (local only)", role: .destructive) {
                    do { try ReviewQueue.reject(selection, context: context); onQueueChange(); selection.removeAll(); discardError = "" }
                    catch { discardError = "Could not reject selected items: \(error.localizedDescription)" }
                }
                .buttonStyle(.bordered)
                .disabled(selection.isEmpty)
                Button("Sync pending", systemImage: "arrow.up.circle") {
                    Task { await hub?.syncPending() }
                }
                .disabled(rows.isEmpty || hub?.syncStatus == "Syncing pending…")
                .help("Deliver confirmed, redaction-gated submissions to the configured backend; moderation remains separate")
                Button(recoveringReceipts ? "Recovering…" : "Recover CloudKit history", systemImage: "arrow.down.circle") {
                    recoveringReceipts = true
                    Task {
                        await hub?.recoverDeliveredReceipts()
                        recoveringReceipts = false
                    }
                }
                .disabled(recoveringReceipts)
                .help("Reconcile creator-readable CloudKit submissions into local delivery history")
                Button(sendingCloudKit ? "Sending…" : "Send CloudKit to Moderation", systemImage: "arrow.right.circle") {
                    sendingCloudKit = true
                    Task {
                        await hub?.sendCloudKitHistoryToModeration()
                        sendingCloudKit = false
                    }
                }
                .disabled(sendingCloudKit)
                .help("Copy creator-owned CloudKit submissions through the redaction gate into the reference moderation queue")
            }
            Text(hub?.syncStatus ?? "Local review only · backend delivery is not connected")
                .font(.caption).foregroundStyle(.secondary)
            if let receipt = hub?.lastReceiptSummary, !receipt.isEmpty {
                Label(receipt, systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            if !rows.isEmpty && evidenceCount < rows.count {
                Label("\(rows.count - evidenceCount) queued item(s) have no recoverable image. Hashes can verify an image when bytes exist, but cannot recreate missing bytes.", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if !discardError.isEmpty { Text(discardError).foregroundStyle(.red) }
            Text("Use Command-click or Shift-click to select multiple items. Rejection removes the selected local queue entries.")
                .font(.caption).foregroundStyle(.secondary)
            Table(table, selection: $selection) {
                TableColumn("Image") { EvidenceThumbnail(image: $0.thumbnail) }.width(min: 72, ideal: 80)
                TableColumn("Captured") { row in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.captured, format: .dateTime.month(.twoDigits).day(.twoDigits).year(.twoDigits))
                        Text(row.captured, format: .dateTime.hour().minute().second()).foregroundStyle(.secondary)
                    }.font(.caption).help(row.captured.formatted())
                }.width(110)
                TableColumn("Agency") { Text($0.agency).lineLimit(2).help($0.agency) }.width(min: 110, ideal: 170, max: 280)
                TableColumn("Unit") { Text($0.unit).help($0.unit) }.width(64)
                TableColumn("Area") { Text($0.area).monospaced() }.width(65)
                TableColumn("Fleet") { Text($0.confidence, format: .percent.precision(.fractionLength(0))) }.width(55)
                TableColumn("Review") { row in
                    Label(row.confirmed ? "Confirmed" : "Pending", systemImage: row.confirmed ? "checkmark.seal.fill" : "clock")
                        .foregroundStyle(row.confirmed ? Color.green : Color.secondary)
                        .help(row.confirmed ? "Operator confirmed" : "Awaiting operator confirmation")
                }.width(92)
                TableColumn("Retries") { Text("\($0.retries)") }.width(48)
                TableColumn("Last error") { Text($0.error).foregroundStyle(.secondary).help($0.error) }.width(min: 80, ideal: 140)
            }
            .overlay {
                if rows.isEmpty { ContentUnavailableView("Nothing queued for review", systemImage: "tray", description: Text("Fleet sightings appear here after on-device analysis.")) }
            }
            .onChange(of: rows.map(\.persistentModelID)) { _, ids in selection.formIntersection(ids) }
            if selection.count == 1, let row = table.first(where: { selection.contains($0.id) }) { UnitRecordsStrip(unit: row.unit, agencyKey: row.agencyKey) }
            Text("Evidence crops ride in the local queue and are view-only here; the backend keeps the crop hash, never image bytes. Discarding here does not retract anything already delivered.")
                .font(.caption).foregroundStyle(.secondary)
            if !receipts.isEmpty {
                DisclosureGroup(isExpanded: $showDeliveryHistory) {
                    Table(receiptRows) {
                        TableColumn("Received") { row in Text(row.receivedAt, format: .dateTime) }
                            .width(min: 130, ideal: 160)
                        TableColumn("Sighting") { row in Text(row.sightingID.uuidString.prefix(8)).monospaced() }
                            .width(78)
                        TableColumn("State") { row in Text(row.state) }
                            .width(88)
                        TableColumn("Review") { row in Text(row.confirmed ? "Confirmed" : "Unconfirmed") }
                            .width(100)
                        TableColumn("Evidence") { row in Text(row.hasEvidence ? "Saved" : "Hash only") }
                            .width(82)
                    }
                    .frame(minHeight: 76, idealHeight: min(CGFloat(receiptRows.count * 30 + 34), 190))
                    Text("These are local delivery receipts. CloudKit submissions remain private until a moderator publishes them; an empty Moderation pane is expected when delivery used CloudKit.")
                        .font(.caption).foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } label: {
                    Label("Delivery history · \(receipts.count)", systemImage: "checkmark.seal")
                        .font(.headline)
                }
            }
        }.padding()
        .task(id: rows.map(\.idempotencyKey)) {
            for row in rows {
                guard !Task.isCancelled else { return }
                if let dto = try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: row.payloadJSON),
                   let hash = dto.cropHashSHA256,
                   let data = EvidenceArchive.current.resolve(base64: dto.cropJPEGBase64, hash: hash) {
                    try? EvidenceArchive.current.store(data, hash: hash)
                }
                await Task.yield()
            }
        }
    }

    private struct ReceiptRow: Identifiable {
        let id: UUID
        let sightingID: UUID
        let receivedAt: Date
        let state: String
        let confirmed: Bool
        let hasEvidence: Bool
    }

    private var receiptRows: [ReceiptRow] {
        receipts.map {
            ReceiptRow(id: $0.sightingID, sightingID: $0.sightingID, receivedAt: $0.receivedAt,
                       state: $0.moderationState.rawValue, confirmed: $0.operatorConfirmed,
                       hasEvidence: $0.cropJPEGData != nil)
        }
    }
}

/// The evidence image at thumbnail size; click to inspect at full resolution.
private struct EvidenceThumbnail: View {
    let image: NSImage?
    @State private var enlarged = false

    var body: some View {
        if let image {
            Button { enlarged = true } label: {
                Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 64, height: 40)
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary))
                .contentShape(RoundedRectangle(cornerRadius: 5))
            }.buttonStyle(.plain)
                .accessibilityLabel("View fleet vehicle evidence image")
                .help("Click to view the saved evidence image at full size")
                .sheet(isPresented: $enlarged) { EvidenceViewer(image: image) }
        } else {
            Image(systemName: "photo")
                .foregroundStyle(.tertiary)
                .frame(width: 64, height: 40)
                .help("No image saved: an older record, unavailable frame, or a crop omitted by privacy rules")
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
        .frame(minWidth: max(520, image.size.width + 48), minHeight: max(400, image.size.height + 100))
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
