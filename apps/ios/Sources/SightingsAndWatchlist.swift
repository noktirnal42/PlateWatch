import PlateKit
import PlateSync
import SwiftData
import SwiftUI
import UIKit

/// The outbox is paired with a privacy-safe receipt history. Payloads leave
/// the device after acknowledgement; only delivery metadata and an optional
/// bounded review crop remain locally.
struct SightingsListView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.syncBackend) private var backend
    @Query(sort: \PendingSubmission.createdAt, order: .reverse) private var outbox: [PendingSubmission]
    @Query(sort: \ReceivedSubmissionReceipt.receivedAt, order: .reverse) private var receipts: [ReceivedSubmissionReceipt]
    @State private var errorText: String?
    @State private var publicSightings: [PublicSightingDTO] = []
    @State private var publicError: String?
    @State private var backendStatus = "Not checked"
    @State private var loadingPublic = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PWSectionIntro(eyebrow: "DEVICE OUTBOX", title: "Evidence, ready for review.",
                                   message: "Your queued observations stay here until the shared database receives them.",
                                   systemImage: "tray.full.fill")
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 8, leading: 0, bottom: 12, trailing: 0))
                }
                if outbox.isEmpty {
                    PWEmptyState(title: "Your queue is clear",
                                 message: "Capture or import a public fleet vehicle to create an observation. Received submissions leave this queue; an empty queue does not prove publication.",
                                 systemImage: "checkmark")
                    .listRowBackground(Color.clear).listRowSeparator(.hidden)
                } else {
                    Section {
                        ForEach(outbox) { row in
                            NavigationLink { SightingDetailView(row: row) } label: { SightingRow(row: row) }
                                .accessibilityIdentifier("sighting-" + row.idempotencyKey)
                        }
                        .onDelete(perform: discard)
                    } header: { Text("Waiting to send · \(outbox.count)") } footer: {
                        Text("Swipe to discard a local queued copy. If a transfer has already started, discarding cannot retract it from the backend.")
                    }
                }
                Section {
                    if loadingPublic {
                        HStack { ProgressView(); Text("Loading published sightings…") }
                    } else if let publicError {
                        Label(publicError, systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    } else if publicSightings.isEmpty {
                        Label("No published sightings yet", systemImage: "dot.radiowaves.left.and.right")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(publicSightings, id: \.id) { sighting in
                            PublicSightingRow(sighting: sighting)
                        }
                    }
                } header: {
                    Text("Public feed · \(publicSightings.count)")
                } footer: {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Only moderator-published fleet sightings appear here. Plates and exact locations are withheld from this mobile list.")
                        Label(backendStatus, systemImage: backendStatus.localizedCaseInsensitiveContains("Connected") ? "checkmark.circle" : "network.slash")
                            .foregroundStyle(backendStatus.localizedCaseInsensitiveContains("Connected") ? .green : .secondary)
                    }
                }
                Section {
                    if receipts.isEmpty {
                        Label("No received submissions yet", systemImage: "tray")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(receipts) { receipt in
                            NavigationLink { ReceiptDetailView(receipt: receipt) } label: {
                                ReceiptRow(receipt: receipt)
                            }
                            .accessibilityIdentifier("receipt-" + receipt.sightingID.uuidString)
                        }
                    }
                } header: {
                    Text("Received · \(receipts.count)")
                } footer: {
                    Text("Receipts confirm backend acceptance. This state refreshes to Fleet confirmed when the public feed returns the same ID; a missing row is not treated as withdrawal. Only a bounded local review crop may remain in this history.")
                }
            }
            .safeAreaInset(edge: .top) { PreviewBanner() }
            .navigationTitle("Sightings")
            .refreshable { await loadPublicSightings() }
            .task { await loadPublicSightings() }
            .alert("Could not save", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func discard(_ offsets: IndexSet) {
        for index in offsets { modelContext.delete(outbox[index]) }
        do { try modelContext.save() } catch { modelContext.rollback(); errorText = error.localizedDescription }
    }

    private func loadPublicSightings() async {
        guard !loadingPublic else { return }
        loadingPublic = true
        publicError = nil
        defer { loadingPublic = false }
        do {
            let delta = try await backend.pullSightings(since: nil)
            publicSightings = Array(delta.sightings.prefix(100))
            let publishedIDs = ReceiptPublicationMatcher.publishedIDs(from: delta.sightings)
            var receiptsChanged = false
            for receipt in receipts where publishedIDs.contains(receipt.sightingID)
                && receipt.moderationState != .fleetConfirmed {
                receipt.moderationStateRaw = Sighting.ModerationState.fleetConfirmed.rawValue
                receiptsChanged = true
            }
            if receiptsChanged { try? modelContext.save() }
            backendStatus = "Connected · public feed readable"
        } catch {
            publicSightings = []
            publicError = "Public sightings could not be loaded. Check the connection in About."
            backendStatus = await BackendDiagnostics.status(for: backend)
        }
    }
}

private struct PublicSightingRow: View {
    let sighting: PublicSightingDTO

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "car.fill")
                .foregroundStyle(PWStyle.fleetText)
                .frame(width: 36, height: 36)
                .background(PWStyle.fleet.opacity(0.15), in: .rect(cornerRadius: 10))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text(sighting.agencyName ?? "Fleet vehicle").font(.headline)
                Text(sighting.capturedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
                Text("Area \(sighting.geohash6) · fleet \(Int(sighting.fleetConfidence * 100))%")
                    .font(.caption2.monospaced()).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Published fleet sighting")
    }
}

private struct ReceiptRow: View {
    let receipt: ReceivedSubmissionReceipt

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: receipt.moderationState == .fleetConfirmed ? "checkmark.seal.fill" : "arrow.down.doc.fill")
                .font(.title3)
                .foregroundStyle(receipt.moderationState == .fleetConfirmed ? PWStyle.fleetText : .secondary)
                .frame(width: 40, height: 40)
                .background(Color.secondary.opacity(0.12), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.moderationState.displayName).font(.headline)
                Text(receipt.receivedAt, format: .dateTime.month(.abbreviated).day().hour().minute())
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if receipt.operatorConfirmed {
                Image(systemName: "person.badge.checkmark")
                    .foregroundStyle(PWStyle.fleetText)
                    .accessibilityLabel("Operator confirmed")
            }
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
    }
}

private struct ReceiptDetailView: View {
    let receipt: ReceivedSubmissionReceipt

    var body: some View {
        List {
            Section {
                PWSectionIntro(eyebrow: "BACKEND RECEIPT", title: receipt.moderationState.displayName,
                message: "The backend accepted this submission. The local ledger keeps only the bounded review crop when one was available; raw frames and the original payload are not retained.",
                               systemImage: "checkmark.seal.fill")
                .listRowBackground(Color.clear)
            }
            Section("Delivery") {
                LabeledContent("Received") { Text(receipt.receivedAt, format: .dateTime.month().day().year().hour().minute()) }
                LabeledContent("Sighting ID") { Text(receipt.sightingID.uuidString.prefix(8) + "…").font(.caption.monospaced()) }
                if let prefix = receipt.idempotencyPrefix {
                    LabeledContent("Receipt key") { Text(prefix + "…").font(.caption.monospaced()) }
                }
                LabeledContent("Operator confirmation", value: receipt.operatorConfirmed ? "Confirmed" : "Not recorded")
            }
            if let data = receipt.cropJPEGData, let image = UIImage(data: data) {
                Section {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .clipShape(.rect(cornerRadius: 12))
                        .accessibilityLabel("Saved bounded review crop")
                } header: {
                    Text("Review crop")
                } footer: {
                    Text("This is the local, bounded crop captured for review. It is not a raw camera frame and was not uploaded by PlateSync.")
                }
            }
            Section {
                Label("Publication still requires moderation and policy checks.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .safeAreaInset(edge: .top) { PreviewBanner() }
        .navigationTitle("Receipt")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private extension Sighting.ModerationState {
    var displayName: String {
        switch self {
        case .pending: "Pending review"
        case .fleetConfirmed: "Fleet confirmed"
        case .redacted: "Redacted by policy"
        case .rejected: "Rejected"
        }
    }
}

private struct SightingRow: View {
    let row: PendingSubmission
    private var submission: SightingSubmissionDTO? {
        try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: row.payloadJSON)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "car.side.fill")
                .font(.title3).foregroundStyle(PWStyle.fleetText)
                .frame(width: 40, height: 40)
                .background(PWStyle.fleet.opacity(0.15), in: .rect(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 7) {
                Text(submission.map { SightingPresentation(submission: $0).title } ?? "Unreadable observation").font(.headline)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { metadata }
                    VStack(alignment: .leading, spacing: 6) { metadata }
                }
                SyncStatusPill(retryCount: row.retryCount)
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var metadata: some View {
        if let plate = submission?.plate?.text { PlateBadge(text: plate, compact: true) }
        Text(row.createdAt, format: .dateTime.month(.abbreviated).day().hour().minute())
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct SightingDetailView: View {
    let row: PendingSubmission
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDiscard = false
    @State private var errorText: String?
    private var submission: SightingSubmissionDTO? {
        try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: row.payloadJSON)
    }

    var body: some View {
        List {
            if let submission {
                Section {
                    PWSectionIntro(eyebrow: "QUEUED OBSERVATION", title: SightingPresentation(submission: submission).title,
                                   message: "Recorded on this device. Publication requires backend moderation.", systemImage: "doc.text.viewfinder")
                    .listRowBackground(Color.clear)
                }
                if let identity = submission.identity, !identity.isEmpty {
                    Section("Vehicle identity & evidence") { IdentityCard(identity: identity) }
                } else {
                    Section("Observed markings") {
                        if let plate = submission.plate { PlateBadge(text: plate.text) }
                        if let agency = submission.markings?.agencyText { LabeledContent("Read on vehicle", value: agency) }
                        if let unit = submission.markings?.unitNumber { LabeledContent("Unit", value: unit) }
                        LabeledContent("Vehicle class", value: submission.vehicle.vehicleClass.capitalized)
                    }
                }
                Section {
                    LabeledContent("Captured") { Text(submission.capturedAt, format: .dateTime.month().day().year().hour().minute()) }
                    LabeledContent("Coarse area", value: submission.geohash6.isEmpty ? "Not recorded" : submission.geohash6)
                    LabeledContent("Fleet evidence score", value: "\(Int(submission.fleetConfidence * 100))%")
                } header: { Text("Observation") } footer: {
                    Text("The score combines recognition cues; it is not a calibrated probability. Area is a geohash bucket of about 1 km. Raw media is not stored in this queue by the capture flow.")
                }
                Section {
                    ShareLink(item: SightingPresentation(submission: submission).shareText) {
                        Label("Share observation summary", systemImage: "square.and.arrow.up")
                    }
                } footer: { Text("Shares a text summary with coarse area. Device identifiers, precise coordinates and raw media are excluded.") }
            } else {
                ContentUnavailableView("Observation unreadable", systemImage: "doc.questionmark", description: Text("This queued payload could not be decoded. You can discard the local copy."))
            }
            Section {
                SyncStatusPill(retryCount: row.retryCount)
                if row.retryCount >= 8 {
                    Button("Resume automatic retries", systemImage: "arrow.clockwise") {
                        row.retryCount = 0; row.lastError = nil
                        save()
                    }
                }
                Button("Discard queued copy", systemImage: "trash", role: .destructive) { confirmDiscard = true }
            } header: { Text("Delivery") } footer: {
                Text(row.retryCount >= 8 ? "Automatic retries paused after eight failures. Resume retries to try again on the next sync cycle." : "Delivery retries while the app is active. A backend receipt removes this local copy; it does not confirm public publication.")
            }
        }
        .safeAreaInset(edge: .top) { PreviewBanner() }
            .navigationTitle("Observation").navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("Discard this queued copy?", isPresented: $confirmDiscard, titleVisibility: .visible) {
            Button("Discard queued copy", role: .destructive) {
                modelContext.delete(row)
                if save() { dismiss() }
            }
        } message: { Text("This removes the local copy. A submission already received or in flight cannot be retracted here.") }
        .alert("Could not save", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(errorText ?? "") }
    }

    @discardableResult private func save() -> Bool {
        do { try modelContext.save(); return true }
        catch { modelContext.rollback(); errorText = error.localizedDescription; return false }
    }
}

struct WatchlistView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \WatchlistItem.createdAt, order: .reverse) private var items: [WatchlistItem]
    @State private var newPlate = ""
    @State private var fleetAttested = false
    @State private var errorText: String?
    @FocusState private var plateFocused: Bool

    private var validation: String? { FleetWatchlistInput.validationMessage(newPlate, existing: items.compactMap(\.plateText)) }
    private var canAdd: Bool { validation == nil && fleetAttested }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    PWSectionIntro(eyebrow: "LOCAL WATCHLIST", title: "Keep public fleets in view.",
                                   message: "Watch known public fleet plates. Matching happens on your device.", systemImage: "eye.fill")
                    .listRowBackground(Color.clear)
                }
                Section {
                    TextField("Fleet plate, e.g. GOV123", text: $newPlate)
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .font(.body.monospaced()).focused($plateFocused)
                        .submitLabel(.done).onSubmit { if canAdd { add() } else { plateFocused = false } }
                        .accessibilityLabel("Public fleet plate").accessibilityIdentifier("fleet-plate-input")
                    if !newPlate.isEmpty, let validation {
                        Label(validation, systemImage: "exclamationmark.circle")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Toggle("This is a publicly funded fleet vehicle", isOn: $fleetAttested)
                        .font(.subheadline)
                        .accessibilityHint("Turn this on only when the vehicle is publicly funded")
                        .accessibilityIdentifier("fleet-attestation")
                    Button(action: add) {
                        Label("Add to watchlist", systemImage: "plus.circle.fill").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent).tint(PWStyle.fleet).foregroundStyle(.black)
                    .disabled(!canAdd)
                } header: { Text("Add a fleet plate") } footer: {
                    Text("Entries stay on this device and are never published. Private-citizen vehicles are outside PlateWatch’s scope. Notification permission is requested when you add a plate.")
                }
                Section("Watching · \(items.count)") {
                    if items.isEmpty {
                        Label("No fleet plates on watch yet", systemImage: "eye.slash").foregroundStyle(.secondary)
                    }
                    ForEach(items) { item in
                        HStack(spacing: 12) {
                            if let plate = item.plateText { PlateBadge(text: plate) }
                            else { Label("Vehicle re-ID anchor", systemImage: "scope") }
                            Spacer()
                            Button {
                                item.notifyEnabled.toggle()
                                persist()
                            } label: {
                                Image(systemName: item.notifyEnabled ? "bell.fill" : "bell.slash")
                                    .foregroundStyle(item.notifyEnabled ? PWStyle.fleetText : .secondary)
                                    .frame(minWidth: 44, minHeight: 44)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("\(item.notifyEnabled ? "Mute" : "Enable") alerts for \(item.plateText ?? "vehicle")")
                        }
                    }
                    .onDelete { offsets in
                        for index in offsets { modelContext.delete(items[index]) }
                        persist()
                    }
                }
            }
            .safeAreaInset(edge: .top) { PreviewBanner() }
            .navigationTitle("Watchlist")
            // Keep dismissal reachable when the iOS keyboard's return key is
            // outside the accessibility viewport (large text and simulator
            // keyboards can place that key below the scroll container).
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") { plateFocused = false }
                        .accessibilityIdentifier("watchlist-keyboard-done")
                }
            }
            .task { plateFocused = true }
            .alert("Could not save watchlist", isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(errorText ?? "") }
        }
    }

    private func add() {
        guard canAdd else { return }
        modelContext.insert(WatchlistItem(plateText: Plate.normalize(newPlate)))
        guard persist() else { return }
        newPlate = ""; fleetAttested = false; plateFocused = false
        NotificationPermission.requestIfNeeded()
    }

    @discardableResult private func persist() -> Bool {
        do {
            try modelContext.save()
            // Derive the push-handler copy from the saved models on every mutation,
            // including deletion and mute. Never append to an outdated defaults array.
            let saved = try modelContext.fetch(FetchDescriptor<WatchlistItem>())
            if !PreviewFixtures.isEnabled {
                let plates = WatchlistNotificationMirror.plates(from: saved)
                UserDefaults.standard.set(plates, forKey: "watchlistPlates")
                WatchlistConnectivity.shared.send(plates: plates)
            }
            return true
        } catch { modelContext.rollback(); errorText = error.localizedDescription; return false }
    }
}
