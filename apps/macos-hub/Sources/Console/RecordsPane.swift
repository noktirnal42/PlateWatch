import AppKit
import FleetImporters
import PlateKit
import SwiftUI

/// Records & FOIA: the public-records side of the mission. Two tools:
///
/// 1. **FOIA requests** — drafts a fleet-focused public-records letter with
///    `FOIARequestGenerator` (text only; nothing is sent anywhere). The
///    generator's guardrails are encoded upstream: it never asks for employee
///    names, home addresses, or driver records, and unit numbers are
///    validated so the letter cannot carry personal information.
/// 2. **Public records directory** — curated, cited starting points for
///    researching agencies and officials (rosters, decertification registers,
///    court dockets, watchdog datasets). Every record imported from these
///    sources must carry a `SourceCitation` (AGENTS.md guardrail 2).
struct RecordsPane: View {
    enum Section: String, CaseIterable, Identifiable {
        case foia = "FOIA requests", directory = "Public records directory"
        var id: String { rawValue }
    }

    @State private var section: Section = .foia

    var body: some View {
        VStack(spacing: 0) {
            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding([.top, .horizontal])
            switch section {
            case .foia: FOIADraftView()
            case .directory: RecordsDirectory()
            }
        }
        .padding(.bottom)
    }
}

// MARK: - FOIA drafts

private struct FOIADraftView: View {
    @State private var agencyName = ""
    @State private var stateName = ""
    @State private var recordsURL = ""
    @State private var units = ""
    @State private var scope = FOIARequestGenerator.Scope()
    @State private var draft: FOIARequestGenerator.Draft?
    @State private var status = ""

    private let generator = FOIARequestGenerator()

    var body: some View {
        HSplitView {
            Form {
                Section("Agency") {
                    TextField("Agency name (e.g. Waltham Police Department)", text: $agencyName)
                    TextField("State (optional)", text: $stateName)
                    TextField("Records portal URL (optional)", text: $recordsURL)
                }
                Section("Scope") {
                    Toggle("Fleet inventory (units, make, model, plate)", isOn: $scope.fleetInventory)
                    Toggle("Unit ↔ vehicle links", isOn: $scope.unitVehicleLinks)
                    Toggle("ALPR usage policy", isOn: $scope.alprPolicy)
                    Toggle("ALPR retention schedules + deletion logs", isOn: $scope.alprRetention)
                    Toggle("ALPR vendor contracts", isOn: $scope.alprVendorContracts)
                }
                Section("Observed unit numbers (optional)") {
                    TextField("e.g. D756, K9-2, 4471", text: $units)
                    Text("Validated to unit identifiers (1–12 of A–Z 0–9 - /). Names, plates with spaces, and anything else is rejected so the letter cannot carry personal information.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button("Draft request") { makeDraft() }
                    .buttonStyle(.borderedProminent)
                    .disabled(agencyName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .formStyle(.grouped)
            .frame(minWidth: 380, maxWidth: 480)

            VStack(alignment: .leading, spacing: 8) {
                if let draft {
                    LabeledContent("Subject", value: draft.subject)
                    TextEditor(text: .constant(bodyText(draft)))
                        .font(.system(size: 12, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Button("Copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(bodyText(draft), forType: .string)
                            status = "Copied."
                        }
                        Button("Save as .txt") { save(draft) }
                        Button("MuckRock") { NSWorkspace.shared.open(URL(string: "https://www.muckrock.com/")!) }
                        Spacer()
                        if !draft.rejectedUnits.isEmpty {
                            Text("Rejected as personal data: \(draft.rejectedUnits.joined(separator: ", "))")
                                .font(.caption).foregroundStyle(.orange)
                        }
                        if !status.isEmpty {
                            Text(status).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Text("The draft is text only — nothing is sent anywhere. Review, fill in your contact block, and file through the agency's portal or MuckRock.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    ContentUnavailableView("No draft yet",
                                           systemImage: "doc.text.magnifyingglass",
                                           description: Text("Enter an agency, choose the record categories, and draft a public-records request."))
                }
            }
            .padding()
            .frame(minWidth: 420, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }

    /// The body with a filled-in contact block so the letter is ready to paste.
    private func bodyText(_ draft: FOIARequestGenerator.Draft) -> String {
        draft.body
    }

    private func makeDraft() {
        let target = FOIARequestGenerator.Target(
            agencyName: agencyName.trimmingCharacters(in: .whitespaces),
            recordsOfficeURL: URL(string: recordsURL.trimmingCharacters(in: .whitespaces)),
            stateName: stateName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : stateName.trimmingCharacters(in: .whitespaces))
        draft = generator.draft(target: target,
                                units: units.split(whereSeparator: { ",; ".contains($0) }).map(String.init),
                                scope: scope)
        status = ""
    }

    private func save(_ draft: FOIARequestGenerator.Draft) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "\(draft.subject).txt".replacingOccurrences(of: ":", with: "-")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try bodyText(draft).write(to: url, atomically: true, encoding: .utf8)
            status = "Saved \(url.lastPathComponent)."
        } catch {
            status = "Save failed: \(error.localizedDescription)"
        }
    }
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

private struct RecordsDirectory: View {
    @State private var query = ""

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

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Filter directory (name, state, note)", text: $query)
                    .textFieldStyle(.roundedBorder)
            }
            .padding(.horizontal)
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(grouped, id: \.0) { category, items in
                        Text(category.rawValue).font(.headline).padding(.horizontal)
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
                            .padding(.horizontal)
                        }
                    }
                    Text("Starting points, not endorsements: verify each source's current location, terms and license before importing. The National Decertification Index is not public — use the state registers above. Every imported record must carry a SourceCitation, and docket allegations are stored verbatim, never stated as fact (docs/ACCOUNTABILITY-DATA.md).")
                        .font(.caption).foregroundStyle(.secondary)
                        .padding(.horizontal)
                        .padding(.bottom)
                }
            }
        }
        .padding(.top)
    }
}
