import FleetImporters
import SwiftUI
import UniformTypeIdentifiers

/// Exposes the existing fleet-only request generator. Person-record collection is a separate, cited review pipeline.
struct RecordsPane: View {
    @State private var tab = 0
    @State private var agency = ""
    @State private var state = ""
    @State private var units = ""
    @State private var inventory = true
    @State private var assignments = true
    @State private var policy = true
    @State private var retention = true
    @State private var contracts = false
    @State private var notice = ""

    private var canDraft: Bool {
        !agency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (inventory || assignments || policy || retention || contracts)
    }
    private var draft: FOIARequestGenerator.Draft {
        FOIARequestGenerator().draft(target: .init(agencyName: agency.trimmingCharacters(in: .whitespacesAndNewlines),
                                                  stateName: state.isEmpty ? nil : state),
                                    units: units.components(separatedBy: CharacterSet(charactersIn: ",;\n")),
                                    scope: .init(fleetInventory: inventory, unitVehicleLinks: assignments,
                                                 alprPolicy: policy, alprRetention: retention, alprVendorContracts: contracts))
    }
    private var text: String { "Subject: \(draft.subject)\n\n\(draft.body)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Records workspace", selection: $tab) {
                Text("Fleet FOIA draft").tag(0)
                Text("Public-records programme").tag(1)
            }.pickerStyle(.segmented).frame(maxWidth: 480)
            if tab == 0 { builder } else { programme }
        }.padding()
    }

    private var builder: some View {
        HSplitView {
            Form {
                Section("Agency & scope") {
                    TextField("Public agency", text: $agency).help("Name of the public agency receiving this request")
                    TextField("State (optional)", text: $state)
                    TextField("Unit numbers (optional)", text: $units)
                        .help("Separate public fleet unit numbers with commas; names and addresses are not valid unit numbers")
                    Toggle("Fleet inventory", isOn: $inventory)
                    Toggle("Unit-to-vehicle records", isOn: $assignments)
                    Toggle("ALPR policy", isOn: $policy)
                    Toggle("Retention & deletion records", isOn: $retention)
                    Toggle("Vendor contracts", isOn: $contracts)
                }
                Section {
                    Text("This existing template requests fleet and policy records. It excludes employee names, private contact details and DMV records. Requester details remain placeholders.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Draft only. Review, personalize and file it yourself through the agency's records portal.")
                        .font(.caption).foregroundStyle(.secondary)
                    Link("FOIA documentation", destination: URL(string: "https://github.com/noktirnal42/PlateWatch/blob/main/docs/FOIA.md")!)
                }
            }.formStyle(.grouped).frame(minWidth: 300, idealWidth: 360)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("Request preview", systemImage: "doc.text").font(.headline)
                    Spacer()
                    Button("Copy draft", systemImage: "doc.on.doc") {
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string)
                        notice = "Draft copied. Nothing has been submitted."
                    }.disabled(!canDraft).help("Copy the text with requester placeholders for your review")
                    Button("Save draft…", systemImage: "square.and.arrow.down") { save() }
                        .disabled(!canDraft).help("Save a plain-text draft; this does not send a records request")
                }
                if canDraft {
                    if !draft.rejectedUnits.isEmpty {
                        Label("Excluded invalid unit entries: \(draft.rejectedUnits.joined(separator: ", "))", systemImage: "exclamationmark.triangle")
                            .font(.caption).foregroundStyle(.orange)
                    }
                    ScrollView { Text(text).font(.system(.body, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading).padding(12) }
                        .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 10))
                } else {
                    ContentUnavailableView("Draft a fleet records request", systemImage: "doc.badge.plus",
                                           description: Text("Enter an agency and choose at least one record category. Your identity is never filled in automatically."))
                }
                if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
            }.frame(minWidth: 420).padding(.leading, 12)
        }
    }

    private var programme: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Label("Public records, with evidence", systemImage: "doc.text.magnifyingglass").font(.largeTitle.bold())
                Text("Planned collection workflow — automated person-record ingestion is not running.")
                    .foregroundStyle(.secondary)
                GroupBox("Sources") {
                    Text("Agency rosters and employee lists; official bios and award announcements; agency-published social posts; released Brady/Giglio lists and decertification registers; court dockets, filings and outcomes; public-records responses.")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("Cross-reference, then review") {
                    Text("Find candidate links using published names, agencies, roles, identifiers and dates. Keep the original URL, publisher, retrieval date, excerpt and case status for every claim. Name-only matches remain ambiguous; a moderator confirms each person/record link before publication. Allegations, findings and outcomes remain distinct.")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                GroupBox("Photos & camera boundary") {
                    Text("Official photo links can accompany a cited profile for human reference, subject to rights. Photos are not used for face recognition or matching people in camera footage. Vehicle detections do not identify occupants. Person records have no sightings map, location timeline or presence alerts.")
                        .frame(maxWidth: .infinity, alignment: .leading).padding(6)
                }
                Link("Records programme & implementation plan", destination: URL(string: "https://github.com/noktirnal42/PlateWatch/blob/main/docs/ACCOUNTABILITY-DATA.md")!)
                Link("Source and moderation rules", destination: URL(string: "https://github.com/noktirnal42/PlateWatch/blob/main/docs/LEGAL-ETHICS.md")!)
            }.padding(8)
        }
    }

    private func save() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "PlateWatch-public-records-draft.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try text.write(to: url, atomically: true, encoding: .utf8); notice = "Draft saved. Nothing has been submitted." }
        catch { notice = "Could not save draft: \(error.localizedDescription)" }
    }
}
