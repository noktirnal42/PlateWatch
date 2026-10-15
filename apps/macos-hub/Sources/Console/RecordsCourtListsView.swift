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
                GroupBox("Released lists (CSV)") {
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
            Text("\(workspace.ledger.pending.count) pending · \(workspace.ledger.incidents.count) accepted records").font(.headline)
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
            Text("Accepting stores the record with its citation and hash. Linking a record to a named official is a separate, cited, moderator-confirmed step that is not offered here; a name never links on its own.")
                .font(.caption).foregroundStyle(.secondary)
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
        Task { let n = await workspace.searchPacer(partyName: query); notice = "\(n) new docket(s) added as pending."; busy = false }
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
