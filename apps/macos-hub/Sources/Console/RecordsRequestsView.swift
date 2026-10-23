import AccountabilityKit
import SwiftUI

/// The public-records request tracker. The Hub never files a request — the user files it with the agency, then records
/// the date here and the tracker computes the statutory due date and follow-up/appeal text.
struct RecordsRequestsView: View {
    @State private var workspace = RecordsWorkspace.shared
    @State private var selection: FOIARequest.ID?
    @State private var newAgency = ""
    @State private var newState = ""
    @State private var newSubject = ""
    @State private var noteText = ""
    @State private var status: FOIARequest.Status = .acknowledged
    @State private var message = ""

    private var selected: FOIARequest? { workspace.tracker.requests.first { $0.id == selection } }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                List(workspace.tracker.requests, selection: $selection) { r in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text(r.agencyName).fontWeight(.medium)
                            if r.isOverdue(asOf: Date()) { Text("overdue").font(.caption2).padding(.horizontal, 5).background(.red.opacity(0.2), in: Capsule()) }
                        }
                        Text("\(r.status.rawValue) · \(r.subject)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }.tag(r.id)
                }
                GroupBox("New request") {
                    VStack(alignment: .leading) {
                        TextField("Agency", text: $newAgency)
                        HStack {
                            TextField("State (e.g. IL, or US)", text: $newState).frame(width: 150)
                            TextField("Subject", text: $newSubject)
                        }
                        Button("Add draft", systemImage: "plus") {
                            let r = FOIARequest(agencyName: newAgency, stateCode: newState.isEmpty ? nil : newState, subject: newSubject,
                                                body: "Use the Fleet FOIA draft tab, then paste the text here when you file.")
                            workspace.tracker.upsert(r); selection = r.id
                            newAgency = ""; newState = ""; newSubject = ""
                        }.disabled(newAgency.trimmingCharacters(in: .whitespaces).isEmpty || newSubject.trimmingCharacters(in: .whitespaces).isEmpty)
                    }.padding(4)
                }
            }.frame(width: 320)
            Divider()
            if let r = selected { detail(r) } else {
                ContentUnavailableView("Track a records request", systemImage: "tray.full",
                                       description: Text("Add the request after you file it with the agency. Due dates come from a short table of statutes marked unverified — you can override any date."))
            }
        }
    }

    @ViewBuilder private func detail(_ r: FOIARequest) -> some View {
        let rule = FOIADeadlines.rule(forState: r.stateCode, asOf: r.submittedOn ?? Date())
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(r.agencyName).font(.title3.bold())
                Text(r.subject)
                HStack {
                    Label(r.status.rawValue, systemImage: "circle.fill").foregroundStyle(r.isOverdue(asOf: Date()) ? .red : .accentColor)
                    if let due = r.dueOn { Text("Due \(due, format: .dateTime.year().month().day())\(r.dueDateIsOverride ? " (your date)" : "")") }
                }
                if let rule {
                    Text("\(rule.days) \(rule.businessDays ? "business" : "calendar") days — \(rule.citation) (\(rule.covers.rawValue); statute text not read; weekends skipped, holidays not)")
                        .font(.caption).foregroundStyle(.secondary)
                    if let note = rule.checkedNote { Text(note).font(.caption2).foregroundStyle(.secondary) }
                } else if r.stateCode != nil {
                    Text("No statutory window on file for \(r.stateCode ?? "") — set a due date yourself.").font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    if r.submittedOn == nil {
                        Button("Mark filed today") { edit(r) { $0.markSubmitted(on: Date()) } }
                    }
                    DatePicker("Due", selection: Binding(get: { r.dueOn ?? Date() }, set: { d in edit(r) { $0.setDueDate(d) } }), displayedComponents: .date)
                        .labelsHidden()
                    Picker("Status", selection: $status) { ForEach(FOIARequest.Status.allCases, id: \.self) { Text($0.rawValue).tag($0) } }.frame(width: 190)
                    Button("Update") { edit(r) { try? $0.transition(to: status, on: Date()) } }
                }
                HStack {
                    TextField("Note", text: $noteText)
                    Button("Add note") { edit(r) { $0.addNote(noteText, on: Date()) }; noteText = "" }.disabled(noteText.isEmpty)
                }
                HStack {
                    Button("Receive document…", systemImage: "doc.badge.plus") { receive(r) }
                        .help("Attach a released file: it is hashed and cited as a FOIA release; the file itself is not copied.")
                    Button("Copy appeal / follow-up text", systemImage: "doc.on.doc") {
                        let d = r.appealDraft(asOf: Date())
                        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("Subject: \(d.subject)\n\n\(d.body)", forType: .string)
                        message = "Copied. Review and send it yourself."
                    }
                    Button("Delete", role: .destructive) { workspace.tracker.remove(id: r.id); selection = nil }
                }
                if !r.releases.isEmpty {
                    Text("Released documents").font(.headline)
                    ForEach(Array(r.releases.enumerated()), id: \.offset) { _, rel in
                        Text("\(rel.description)  ·  sha256 \(rel.citation.excerptHashSHA256?.prefix(12) ?? "")…").font(.caption.monospaced())
                    }
                }
                Text("History").font(.headline)
                ForEach(Array(r.events.reversed().enumerated()), id: \.offset) { _, e in
                    Text("\(e.date.formatted(date: .abbreviated, time: .omitted)) — \(e.text)").font(.caption)
                }
                if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary) }
                Text("Draft text is yours to file. Nothing here contacts an agency.").font(.caption2).foregroundStyle(.secondary)
            }.padding().frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func edit(_ r: FOIARequest, _ change: (inout FOIARequest) -> Void) {
        var copy = r; change(&copy); workspace.tracker.upsert(copy)
    }

    private func receive(_ r: FOIARequest) {
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        edit(r) { try? $0.addRelease(description: url.lastPathComponent, fileName: url.lastPathComponent, data: data, receivedOn: Date()) }
    }
}
