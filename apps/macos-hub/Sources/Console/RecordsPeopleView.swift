import AccountabilityKit
import PlateKit
import SwiftUI

/// Officials (public capacity only), unit links and record attachment. Every step is an explicit, cited human action:
/// a link starts as an inference that is never shown, and is confirmed only with an external citation.
struct RecordsPeopleView: View {
    @State private var workspace = RecordsWorkspace.shared
    @State private var name = ""
    @State private var role = ""
    @State private var rosterURL = ""
    @State private var selected: OfficialProfile.ID?
    @State private var unit = ""
    @State private var agencyKey = ""
    @State private var linkURL = ""
    @State private var confirmURL = ""
    @State private var confirmType: SourceCitation.SourceType = .agencyRoster
    @State private var message = ""

    private var profile: OfficialProfile? { workspace.ledger.profiles.first { $0.id == selected } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                List(workspace.ledger.profiles, selection: $selected) { p in
                    VStack(alignment: .leading) { Text(p.name).fontWeight(.medium); Text(p.role).font(.caption).foregroundStyle(.secondary) }.tag(p.id)
                }
                GroupBox("Import a published roster (CSV)") {
                    VStack(alignment: .leading) {
                        Text("Reads only the name, role and unit columns you name; everything else in the file is ignored and not stored. Rows arrive as pending.")
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            Button("Import roster…") { importRoster() }
                            if !workspace.ledger.pendingRoster.isEmpty {
                                Text("\(workspace.ledger.pendingRoster.count) pending").font(.caption)
                            }
                        }
                        ForEach(workspace.ledger.pendingRoster.prefix(8)) { c in
                            HStack {
                                Text("\(c.name) · \(c.role)\(c.unitNumber.map { " · unit \($0)" } ?? "")").font(.caption).lineLimit(1)
                                Button("Accept") { _ = try? workspace.ledger.acceptRoster(candidateID: c.id) }.controlSize(.small)
                                Button("Reject") { workspace.ledger.rejectRoster(candidateID: c.id) }.controlSize(.small)
                            }
                        }
                        if workspace.ledger.pendingRoster.count > 8 { Text("…and \(workspace.ledger.pendingRoster.count - 8) more").font(.caption2) }
                        if !workspace.lastError.isEmpty { Text(workspace.lastError).font(.caption).foregroundStyle(.red) }
                    }.padding(4)
                }
                GroupBox("Add an official (public capacity)") {
                    VStack(alignment: .leading) {
                        TextField("Name as published", text: $name)
                        TextField("Role as published", text: $role)
                        TextField("Source page URL (roster, bio, release)", text: $rosterURL)
                        Button("Add with citation", systemImage: "plus") {
                            guard let url = URL(string: rosterURL), url.scheme?.hasPrefix("http") == true else { message = "A source URL is required."; return }
                            do {
                                let p = try workspace.ledger.addProfile(name: name, role: role,
                                    citation: SourceCitation(sourceType: .agencyRoster, url: url, retrievedAt: Date()))
                                selected = p.id; name = ""; role = ""; rosterURL = ""; message = ""
                            } catch { message = "\(error)" }
                        }.disabled(name.isEmpty || rosterURL.isEmpty)
                        Text("Names, roles and a citation only — no home addresses, family or personal details.").font(.caption2).foregroundStyle(.secondary)
                    }.padding(4)
                }
            }.frame(width: 340)
            Divider()
            if let p = profile { detail(p) } else {
                ContentUnavailableView("Officials and unit links", systemImage: "person.text.rectangle",
                                       description: Text("Add an official with a source, propose which fleet unit they are assigned to, and confirm it with a second, external citation. Only confirmed links ever appear next to a recognised vehicle."))
            }
        }
    }

    @ViewBuilder private func detail(_ p: OfficialProfile) -> some View {
        let links = workspace.ledger.links.filter { $0.officialID == p.id }
        let records = workspace.ledger.incidents.filter { $0.subjectID == p.id }
        let unassigned = workspace.ledger.incidents.filter { $0.subjectID == nil }
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(p.name).font(.title3.bold())
                Text(p.role)
                ForEach(Array(p.citations.enumerated()), id: \.offset) { _, c in if let u = c.url { Link(u.absoluteString, destination: u).font(.caption) } }

                GroupBox("Unit links") {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(links) { l in
                            HStack {
                                Text("\(l.unitNumber) · \(l.agencyKey ?? "?")")
                                Text(l.canPublish ? "confirmed" : "inferred \(Int(l.confidence * 100))% — hidden").font(.caption)
                                    .foregroundStyle(l.canPublish ? .green : .orange)
                                if !l.canPublish {
                                    TextField("External source URL", text: $confirmURL).frame(width: 220)
                                    Picker("", selection: $confirmType) {
                                        ForEach([SourceCitation.SourceType.agencyRoster, .foiaRelease, .openDataPortal, .officialPost], id: \.self) { Text($0.rawValue).tag($0) }
                                    }.labelsHidden().frame(width: 130)
                                    Button("Confirm") { confirm(l) }.disabled(confirmURL.isEmpty)
                                }
                            }
                        }
                        HStack {
                            TextField("Unit no.", text: $unit).frame(width: 90)
                            TextField("Agency key (as recognised)", text: $agencyKey).frame(width: 190)
                            TextField("Source URL", text: $linkURL)
                            Button("Propose link") { propose(p) }.disabled(unit.isEmpty || agencyKey.isEmpty || linkURL.isEmpty)
                        }
                    }.padding(4)
                }
                GroupBox("Cited records") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(records) { r in
                            HStack {
                                Text("\(r.kind.rawValue) · \(r.reference)\(r.status.isEmpty ? "" : " · \(r.status)")").font(.caption)
                                Button("Detach") { if let i = workspace.ledger.incidents.firstIndex(where: { $0.id == r.id }) { workspace.ledger.incidents[i].subjectID = nil } }
                                    .controlSize(.small)
                            }
                        }
                        if !unassigned.isEmpty {
                            Menu("Attach an accepted record…") {
                                ForEach(unassigned) { r in
                                    Button("\(r.kind.rawValue) · \(r.reference)") { try? workspace.ledger.attach(incidentID: r.id, to: p.id) }
                                }
                            }
                            Text("You choose the person. A matching name is not evidence on its own — check the source's agency and dates first.")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }.padding(4)
                }
                Button("Remove this official and their links", role: .destructive) { workspace.ledger.removeProfile(id: p.id); selected = nil }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func propose(_ p: OfficialProfile) {
        guard let url = URL(string: linkURL), url.scheme?.hasPrefix("http") == true else { message = "A source URL is required."; return }
        do {
            try workspace.ledger.proposeLink(profileID: p.id, unitNumber: unit, agencyKey: agencyKey,
                                             citation: SourceCitation(sourceType: .agencyRoster, url: url, retrievedAt: Date()))
            unit = ""; linkURL = ""; message = ""
        } catch { message = "\(error)" }
    }

    private func confirm(_ l: PersonLink) {
        guard let url = URL(string: confirmURL), url.scheme?.hasPrefix("http") == true else { message = "An external source URL is required."; return }
        do { try workspace.ledger.confirmLink(id: l.id, citation: SourceCitation(sourceType: confirmType, url: url, retrievedAt: Date())); confirmURL = ""; message = "" }
        catch { message = "\(error)" }
    }

    private func importRoster() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.commaSeparatedText]
        guard panel.runModal() == .OK, let url = panel.url, let text = try? String(contentsOf: url, encoding: .utf8) else { return }
        let alert = NSAlert()
        alert.messageText = "Import roster \(url.lastPathComponent)"
        alert.informativeText = "Name the agency, where the roster was published, and which headers hold the name, role and unit. Header names must match the file exactly."
        func field(_ placeholder: String) -> NSTextField {
            let f = NSTextField(frame: NSRect(x: 0, y: 0, width: 340, height: 24)); f.placeholderString = placeholder; return f
        }
        let agency = field("Agency name (e.g. Example Police Department)")
        let key = field("Agency key as recognised (optional, needed for unit links)")
        let page = field("URL where this roster is published (required)")
        let nameCol = field("Name column header"), roleCol = field("Role column header (optional)"), unitCol = field("Unit column header (optional)")
        let stack = NSStackView(views: [agency, key, page, nameCol, roleCol, unitCol]); stack.orientation = .vertical
        stack.frame = NSRect(x: 0, y: 0, width: 340, height: 170)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Import"); alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        guard let source = URL(string: page.stringValue), source.scheme?.hasPrefix("http") == true,
              !agency.stringValue.isEmpty, !nameCol.stringValue.isEmpty else {
            workspace.lastError = "Agency, a source URL and the name column are required."; return
        }
        let n = workspace.importRoster(
            csv: text,
            source: .init(title: url.deletingPathExtension().lastPathComponent, agencyName: agency.stringValue,
                          agencyKey: key.stringValue.isEmpty ? nil : key.stringValue, releasedBy: agency.stringValue, url: source),
            columns: .init(name: nameCol.stringValue, role: roleCol.stringValue.isEmpty ? nil : roleCol.stringValue,
                           unit: unitCol.stringValue.isEmpty ? nil : unitCol.stringValue))
        message = "\(n) new roster row(s) added as pending."
    }
}
