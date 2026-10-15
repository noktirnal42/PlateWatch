import AppKit
import FleetImporters
import PlateKit
import SwiftUI
import UniformTypeIdentifiers

/// Exposes the existing fleet-only request generator, a cited directory of
/// public-records starting points, and the person-records programme boundary.
/// Person-record collection is a separate, cited review pipeline (M7).
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
                                                 alprPolicy: policy, alprRetention: retention,
                                                 alprVendorContracts: contracts))
    }
    private var text: String { "Subject: \(draft.subject)\n\n\(draft.body)" }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker("Records workspace", selection: $tab) {
                Text("FOIA draft").tag(0)
                Text("Requests").tag(3)
                Text("Court & lists").tag(4)
                Text("People").tag(5)
                Text("Directory").tag(1)
                Text("Programme").tag(2)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 560)
            switch tab {
            case 0: builder
            case 1: directory
            case 3: RecordsRequestsView()
            case 4: RecordsCourtListsView()
            case 5: RecordsPeopleView()
            default: programme
            }
        }.padding()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var builder: some View {
        HStack(alignment: .top, spacing: 16) {
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
            }.formStyle(.grouped)
                .frame(minWidth: 300, idealWidth: 360, maxWidth: 420, maxHeight: .infinity, alignment: .top)
            Divider()
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
            }.frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - Public records directory

    private struct RecordSource: Identifiable, Hashable {
        enum Category: String, CaseIterable, Identifiable {
            case rosters = "Rosters & agency directories"
            case decertification = "Decertification registers (state POST)"
            case dockets = "Court dockets & case records"
            case watchdog = "Watchdog & research datasets"
            var id: String { rawValue }
        }

        let id = UUID()
        var name: String
        var category: Category
        /// States the source covers; empty = national.
        var states: [String]
        var url: URL
        var note: String
        /// The citation type an import from this source must carry.
        var citationType: SourceCitation.SourceType
    }

    /// Curated starting points — verify each source's current location and
    /// terms before importing; every imported record needs a SourceCitation.
    /// Arizona first (the Hub operator's pilot area), then outward.
    private static let sources: [RecordSource] = [
        RecordSource(name: "Arizona POST — decertification & discipline decisions",
                     category: .decertification, states: ["AZ"],
                     url: URL(string: "https://post.az.gov/")!,
                     note: "Board decisions and orders; verify the current public-documents location.",
                     citationType: .decertificationRegister),
        RecordSource(name: "Arizona Supreme Court — public case lookup",
                     category: .dockets, states: ["AZ"],
                     url: URL(string: "https://www.azcourts.gov/")!,
                     note: "Criminal/civil case search (azcases case lookup). Prefer RECAP for federal district (AZD) filings.",
                     citationType: .courtDocket),
        RecordSource(name: "City of Phoenix open data",
                     category: .rosters, states: ["AZ"],
                     url: URL(string: "https://phoenixopendata.com/")!,
                     note: "City employee and budget datasets (cited public rosters).",
                     citationType: .openDataPortal),
        RecordSource(name: "Arizona @ Your Service — agency directory",
                     category: .rosters, states: ["AZ"],
                     url: URL(string: "https://az.gov/")!,
                     note: "State agency sites publish org charts, budgets and reports.",
                     citationType: .agencyRoster),

        RecordSource(name: "California POST — decertification database",
                     category: .decertification, states: ["CA"],
                     url: URL(string: "https://www.post.ca.gov/")!,
                     note: "Public decertification index under SB 2 (since 2023).",
                     citationType: .decertificationRegister),
        RecordSource(name: "Caltrans CCTV (feeds pane already imports the catalogue)",
                     category: .rosters, states: ["CA"],
                     url: URL(string: "https://cwwp2.dot.ca.gov/documentation/cctv/cctv.htm")!,
                     note: "Camera operator info lives with the feed import.",
                     citationType: .openDataPortal),

        RecordSource(name: "Connecticut POST — decertifications",
                     category: .decertification, states: ["CT"],
                     url: URL(string: "https://portal.ct.gov/post")!,
                     note: "Published decertification actions.",
                     citationType: .decertificationRegister),
        RecordSource(name: "Florida FDLE / CJSTC — officer discipline",
                     category: .decertification, states: ["FL"],
                     url: URL(string: "https://www.fdle.state.fl.us/")!,
                     note: "Criminal Justice Standards & Training Commission disciplinary records.",
                     citationType: .decertificationRegister),
        RecordSource(name: "Georgia POST — standards & decertification",
                     category: .decertification, states: ["GA"],
                     url: URL(string: "https://www.post.ga.gov/")!,
                     note: "Published revocations and orders.",
                     citationType: .decertificationRegister),
        RecordSource(name: "Tennessee POST — decertification database",
                     category: .decertification, states: ["TN"],
                     url: URL(string: "https://www.tn.gov/commission/post.html")!,
                     note: "Public officer/decertification search.",
                     citationType: .decertificationRegister),
        RecordSource(name: "Texas TCOLE — license lookup",
                     category: .decertification, states: ["TX"],
                     url: URL(string: "https://tcole.texas.gov/")!,
                     note: "Peace-officer license status incl. revocations.",
                     citationType: .decertificationRegister),

        RecordSource(name: "CourtListener + RECAP Archive (Free Law Project)",
                     category: .dockets, states: [],
                     url: URL(string: "https://www.courtlistener.com/")!,
                     note: "Free federal dockets and filings; the preferred bulk source (PACER charges and restricts automation).",
                     citationType: .courtDocket),
        RecordSource(name: "PACER",
                     category: .dockets, states: [],
                     url: URL(string: "https://pacer.uscourts.gov/")!,
                     note: "Authoritative but per-page fees; no bulk automated access — verify every docket against the filing.",
                     citationType: .courtDocket),

        RecordSource(name: "Invisible Institute — Citizens Police Data Project",
                     category: .watchdog, states: ["IL"],
                     url: URL(string: "https://citizenspolicedataproject.com/")!,
                     note: "Complaint, roster and misconduct data (Chicago; expanding).",
                     citationType: .newsReport),
        RecordSource(name: "Henry A. Wallace Police Crime Database (BGSU)",
                     category: .watchdog, states: [],
                     url: URL(string: "https://policecrime.bgsu.edu/")!,
                     note: "Academic dataset of officers arrested for crimes, with citations.",
                     citationType: .newsReport),
        RecordSource(name: "GSA Fleet / USAspending",
                     category: .rosters, states: [],
                     url: URL(string: "https://www.gsa.gov/")!,
                     note: "Federal fleet inventory sources already imported by FleetImporters.",
                     citationType: .fleetRegistry),
    ]

    @State private var query = ""

    private var grouped: [(RecordSource.Category, [RecordSource])] {
        let filtered = query.isEmpty
            ? Self.sources
            : Self.sources.filter { $0.name.localizedCaseInsensitiveContains(query)
                || $0.states.joined().localizedCaseInsensitiveContains(query)
                || $0.note.localizedCaseInsensitiveContains(query) }
        return RecordSource.Category.allCases.compactMap { category in
            let items = filtered.filter { $0.category == category }
                .sorted { ($0.states.first ?? "zzz", $0.name) < ($1.states.first ?? "zzz", $1.name) }
            guard !items.isEmpty else { return nil }
            return (category, items)
        }
    }

    private var directory: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter directory (name, state, note)", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.0) { category, items in
                        Text(category.rawValue).font(.headline)
                        ForEach(items) { source in
                            HStack(alignment: .top, spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(source.name).font(.body)
                                        if !source.states.isEmpty {
                                            Text(source.states.joined(separator: ", "))
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 5).padding(.vertical, 1)
                                                .background(.quaternary, in: Capsule())
                                        }
                                    }
                                    Text(source.note).font(.caption).foregroundStyle(.secondary)
                                    Text("Import carries citation type: \(source.citationType.rawValue)")
                                        .font(.caption2).foregroundStyle(.tertiary)
                                }
                                Spacer()
                                Button("Open") { NSWorkspace.shared.open(source.url) }
                                    .buttonStyle(.bordered)
                            }
                        }
                    }
                    Text("Starting points, not endorsements: verify each source's current location, terms and license before importing. The National Decertification Index is not public — use the state registers above. Every imported record must carry a SourceCitation, and docket allegations are stored verbatim, never stated as fact (docs/ACCOUNTABILITY-DATA.md).")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Programme boundary

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
                    Text("Official photo links can accompany a cited profile for human reference, subject to rights. Where every LEGAL-ETHICS Rule 6 condition holds (cited accountability records, cited public photos, on-device matching, human confirmation, counsel-reviewed jurisdiction gate), an operator's own Hub may identify officials with cited records — off by default and never auto-publishing. Private individuals are never enrolled or matched; biometric templates never leave the device. Vehicle detections do not identify occupants. Person records have no sightings map, location timeline or presence alerts.")
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
