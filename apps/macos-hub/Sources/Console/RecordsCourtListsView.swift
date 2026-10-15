import AccountabilityKit
import PlateKit
import SwiftUI

/// Court dockets (CourtListener, optionally PACER) and released lists (Brady/Giglio, POST registers) land here as
/// *pending candidates*. Accepting one makes a cited record; it never links a person by name alone.
struct RecordsCourtListsView: View {
    @State private var workspace = RecordsWorkspace.shared
    @State private var query = ""
    @State private var busy = false
    @State private var notice = ""
    @State private var pacerLogin = ""
    @State private var pacerPassword = ""
    @State private var knownID = RecordCatalog.all[0].id
    @State private var showAccepted = false
    @State private var agencyDrafts: [UUID: String] = [:]
    @State private var pacerOTP = ""
    @State private var pacerClientCode = RecordsCredentials.read(.pacerClientCode) ?? ""
    @State private var clToken = ""
    @State private var extraLimit = ""
    @State private var hasPacer = RecordsCredentials.has(.pacerLogin)

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            sources.frame(width: 360)
            Divider()
            candidates
        }
    }

    private var sources: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                GroupBox("Search courts") {
                    VStack(alignment: .leading) {
                        TextField("Agency or party, e.g. \"Town of Exampleville\" police", text: $query).onSubmit { runCourtListener() }
                        HStack {
                            Button("CourtListener (free)") { runCourtListener() }.disabled(busy || query.isEmpty)
                            Button("PACER") { runPacer() }.disabled(busy || query.isEmpty || !hasPacer)
                                .help(hasPacer ? "Uses your PACER account within the budget below" : "Add a PACER login first")
                        }
                        Text("Results are dockets only — a docket is a filing, not a finding.").font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                GroupBox("Known lists (one click)") {
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("", selection: $knownID) { ForEach(RecordCatalog.all) { Text($0.title).tag($0.id) } }.labelsHidden()
                        if let k = RecordCatalog.source(id: knownID) {
                            Text(k.note).font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("Import", systemImage: "arrow.down.circle") {
                                    busy = true; notice = ""
                                    Task { let n = await workspace.importKnownList(k); notice = "\(n) new record(s) added as pending."; busy = false }
                                }.disabled(busy)
                                Link("Dataset page", destination: k.datasetPage).font(.caption)
                            }
                        }
                        Text("This importer covers official certification actions. Watchdog and news publishers also publish Brady/Giglio records; inspect their original releases before using CSV import.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(4)
                }
                GroupBox("Published Brady/Giglio records") {
                    VStack(alignment: .leading, spacing: 8) {
                        Link("50-a.org · NYC DA credibility lists", destination: URL(string: "https://www.50-a.org/credibility")!)
                        Link("ABC15 · Maricopa Tier 2 list", destination: URL(string: "https://www.abc15.com/news/local-news/investigations/brady-list/database-mcaos-more-secretive-brady-list")!)
                        Text("Research links, not one-click importers. Verify the releasing office, date and original document; allegations and list categories remain distinct. More sources are in Directory.")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(4)
                }
                GroupBox("Other released list (CSV)") {
                    VStack(alignment: .leading) {
                        Text("Import a Brady/Giglio list or POST register that a public body has published. You say who released it and which columns are which.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Import CSV…") { importCSV() }
                    }.padding(4)
                }
                GroupBox("PACER account & budget (optional)") {
                    VStack(alignment: .leading, spacing: 6) {
                        if hasPacer {
                            Label("Login saved in Keychain", systemImage: "checkmark.seal")
                            Button("Remove PACER login") {
                                RecordsCredentials.remove(.pacerLogin); RecordsCredentials.remove(.pacerPassword); hasPacer = false
                            }
                        } else {
                            TextField("PACER username", text: $pacerLogin)
                            SecureField("PACER password", text: $pacerPassword)
                            Button("Save to Keychain") {
                                if RecordsCredentials.write(pacerLogin, for: .pacerLogin), RecordsCredentials.write(pacerPassword, for: .pacerPassword) {
                                    hasPacer = true; pacerLogin = ""; pacerPassword = ""
                                }
                            }.disabled(pacerLogin.isEmpty || pacerPassword.isEmpty)
                        }
                        TextField("Client code (needed for searches; no spaces or commas)", text: $pacerClientCode)
                            .onSubmit { RecordsCredentials.write(pacerClientCode, for: .pacerClientCode) }
                        TextField("MFA code (only if your PACER account uses one; not saved)", text: $pacerOTP)
                        Button("Save client code") { RecordsCredentials.write(pacerClientCode, for: .pacerClientCode) }
                        Divider()
                        let now = Date()
                        Text("This quarter: $\(workspace.budget.spent(in: now) as NSDecimalNumber) spent · free allowance $\(workspace.budget.freeAllowanceUSD as NSDecimalNumber) · $\(workspace.budget.remainingFree(on: now) as NSDecimalNumber) free left")
                            .font(.caption)
                        HStack {
                            Text("Allowed above free: $")
                            TextField("0", text: $extraLimit).frame(width: 70)
                                .onAppear { extraLimit = "\(workspace.budget.extraLimitUSD)" }
                            Button("Set") { if let d = Decimal(string: extraLimit), d >= 0 { workspace.budget.extraLimitUSD = d } }
                        }
                        Text("At $0 (default) PACER requests stop at the free allowance and never bill you. Raise it to allow that many dollars above the free amount per quarter. The free amount ($30) is PACER's published waiver — confirm it on pacer.uscourts.gov.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }.padding(4)
                }
                GroupBox("CourtListener token (optional)") {
                    HStack {
                        SecureField(RecordsCredentials.has(.courtListenerToken) ? "Saved — enter to replace" : "API token", text: $clToken)
                        Button("Save") { RecordsCredentials.write(clToken, for: .courtListenerToken); clToken = "" }.disabled(clToken.isEmpty)
                    }.padding(4)
                }
                if !notice.isEmpty { Text(notice).font(.caption) }
                if !workspace.lastError.isEmpty { Text(workspace.lastError).font(.caption).foregroundStyle(.red) }
            }.padding(.trailing, 4)
        }
    }

    private var candidates: some View {
        VStack(alignment: .leading) {
            Picker("", selection: $showAccepted) {
                Text("\(workspace.ledger.pending.count) pending").tag(false)
                Text("\(workspace.ledger.incidents.count) accepted").tag(true)
            }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
            if showAccepted { accepted } else { pendingList }
            Text("Accepting stores the record with its citation and hash. Attaching a record to a named official is a separate step in the People tab; a name never links on its own.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    /// Accepted records: attach to an agency (they then appear in Review next to that agency's recognised units), attach to an
    /// official, or send back to pending.
    private var accepted: some View {
        List {
            if workspace.ledger.incidents.isEmpty {
                Text("Nothing accepted yet. Accept a pending record and it appears here.").foregroundStyle(.secondary)
            }
            ForEach(workspace.ledger.incidents) { r in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(r.kind.rawValue) · \(r.reference)").fontWeight(.medium)
                    Text(r.status.isEmpty ? "No status published" : r.status).font(.caption).foregroundStyle(.secondary)
                    let person = workspace.ledger.profiles.first { $0.id == r.subjectID }
                    Text(person.map { "Attached to \($0.name)" } ?? (r.agencyKey.map { "Shown for agency \($0)" } ?? "Not attached — it won't appear anywhere yet"))
                        .font(.caption).foregroundStyle(person == nil && r.agencyKey == nil ? .orange : .secondary)
                    HStack {
                        Menu("Show for agency…") {
                            ForEach(RosterCatalog.all) { s in
                                Button("\(s.agencyName) (\(s.agencyKey))") { try? workspace.ledger.setAgency(incidentID: r.id, agencyKey: s.agencyKey) }
                            }
                            Divider()
                            Button("Clear agency") { try? workspace.ledger.setAgency(incidentID: r.id, agencyKey: nil) }
                        }.controlSize(.small).fixedSize()
                        TextField("or type an agency key, e.g. US-MA/boston/police", text: Binding(
                            get: { agencyDrafts[r.id] ?? "" }, set: { agencyDrafts[r.id] = $0 })).frame(width: 260)
                        Button("Set") { try? workspace.ledger.setAgency(incidentID: r.id, agencyKey: agencyDrafts[r.id]); agencyDrafts[r.id] = nil }
                            .controlSize(.small).disabled((agencyDrafts[r.id] ?? "").isEmpty)
                    }
                    HStack {
                        Menu("Attach to official…") {
                            if workspace.ledger.profiles.isEmpty { Text("Add an official in the People tab first") }
                            ForEach(workspace.ledger.profiles) { p in
                                Button(p.name) { try? workspace.ledger.attach(incidentID: r.id, to: p.id) }
                            }
                        }.controlSize(.small).fixedSize()
                        Button("Send back to pending") { workspace.ledger.unaccept(incidentID: r.id) }.controlSize(.small)
                        if let url = r.citations.first?.url { Link("Source", destination: url).font(.caption) }
                    }
                }.padding(.vertical, 2)
            }
        }
    }

    private var pendingList: some View {
        VStack(alignment: .leading) {
            List {
                ForEach(workspace.ledger.pending) { c in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(c.kind.rawValue) · \(c.reference)").fontWeight(.medium)
                        Text([c.subjectName, c.status.isEmpty ? nil : c.status, "released by \(c.releasedBy)"].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                        Text(c.excerpt).font(.caption2).lineLimit(2)
                        HStack {
                            Button("Accept as cited record") { try? workspace.ledger.accept(candidateID: c.id, subject: nil, agencyID: nil) }
                            Button("Reject") { reject(c) }
                            if let url = c.citation.url { Link("Source", destination: url) }
                        }.buttonStyle(.bordered).controlSize(.small)
                    }.padding(.vertical, 2)
                }
            }
        }
    }

    private func reject(_ c: RecordCandidate) {
        guard let i = workspace.ledger.candidates.firstIndex(where: { $0.id == c.id }) else { return }
        workspace.ledger.candidates[i].reject()
    }

    private func runCourtListener() {
        busy = true; notice = ""
        Task { let n = await workspace.searchCourtListener(query: query); notice = "\(n) new docket(s) added as pending."; busy = false }
    }

    private func runPacer() {
        busy = true; notice = ""
        Task { let n = await workspace.searchPacer(partyName: query, otpCode: pacerOTP); notice = "\(n) new docket(s) added as pending."; busy = false }
    }

    private func importCSV() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        // A small modal prompt keeps this honest: the user names the publisher and the columns.
        let alert = NSAlert()
        alert.messageText = "Import \(url.lastPathComponent)"
        alert.informativeText = "Who released this list, and what is in the columns? Use header names exactly as they appear in the file."
        let publisher = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); publisher.placeholderString = "Released by (e.g. Example County DA)"
        let nameCol = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); nameCol.placeholderString = "Name column header"
        let refCol = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); refCol.placeholderString = "Reference column header (optional)"
        let statusCol = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); statusCol.placeholderString = "Status column header (optional)"
        let kind = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 320, height: 24)); kind.addItems(withTitles: ["Brady/Giglio list", "Decertification register"])
        let stack = NSStackView(views: [kind, publisher, nameCol, refCol, statusCol]); stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 320, height: 140)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn, !publisher.stringValue.isEmpty, !nameCol.stringValue.isEmpty else { return }
        let k: IncidentRecord.Kind = kind.indexOfSelectedItem == 0 ? .bradyList : .decertification
        let n = workspace.importList(
            csv: text,
            source: .init(kind: k, title: url.deletingPathExtension().lastPathComponent, releasedBy: publisher.stringValue, url: nil),
            columns: .init(name: nameCol.stringValue, reference: refCol.stringValue.isEmpty ? nil : refCol.stringValue,
                           status: statusCol.stringValue.isEmpty ? nil : statusCol.stringValue))
        notice = "\(n) new row(s) added as pending."
    }
}
