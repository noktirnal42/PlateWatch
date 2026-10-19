import AccountabilityKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// RSS/Atom reader for public-records sources: agency release feeds, court and news feeds. Read-only and local —
/// feed text is untrusted data shown as plain text, and nothing is filed, accepted or published from here.
struct RecordsFeedsView: View {
    @State private var workspace = RecordsWorkspace.shared
    enum Scope: Hashable { case all, feed(UUID), group(String) }
    @State private var scope: Scope = .all
    @State private var itemSelection: String?
    @State private var filter: RSSLibrary.Filter = .all
    @State private var query = ""
    @State private var newURL = ""
    @State private var newGroup = ""
    @State private var busy = false
    @State private var notice = ""
    @State private var readerNotice = ""
    @State private var showSuggestions = false
    @AppStorage("hubRecords_feedsSidebarWidth") private var sidebarWidth = 260.0
    @AppStorage("hubRecords_feedsListWidth") private var listWidth = 330.0

    private var library: RSSLibrary { workspace.rss }
    private var items: [RSSItem] { library.visible(feed: scope.feedID, group: scope.groupName, filter: filter, query: query) }
    private var selectedItem: RSSItem? { library.items.first { $0.id == itemSelection } }

    var body: some View {
        content.sheet(isPresented: $showSuggestions) { suggestionsSheet }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar.frame(width: sidebarWidth)
            ColumnResizeHandle(width: $sidebarWidth, range: 180...420, label: "Resize feeds column")
            list.frame(width: listWidth)
            ColumnResizeHandle(width: $listWidth, range: 260...640, label: "Resize entries column")
            reader.frame(minWidth: 280, maxWidth: .infinity)
        }
    }

    // MARK: feeds

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $scope) {
                Label("All feeds", systemImage: "tray.2").badge(library.unreadCount()).tag(Scope.all)
                ForEach(library.groups, id: \.self) { group in
                    Label(group, systemImage: "folder")
                        .fontWeight(.semibold)
                        .badge(library.unreadCount(inGroup: group))
                        .tag(Scope.group(group))
                        .contextMenu {
                            Button("Mark group read") { workspace.rss.markAllRead(inGroup: group) }
                            Button("Refresh group") { Task { for id in library.feedIDs(inGroup: group) { await workspace.refreshFeed(id) } } }
                        }
                    ForEach(library.subscriptions.filter { $0.group == group }) { feedRow($0).padding(.leading, 14) }
                }
                let ungrouped = library.subscriptions.filter { $0.group.isEmpty }
                if !ungrouped.isEmpty {
                    if !library.groups.isEmpty { Text("Ungrouped").font(.caption).foregroundStyle(.secondary).padding(.top, 4) }
                    ForEach(ungrouped) { feedRow($0) }
                }
            }
            GroupBox("Auto-refresh") {
                HStack {
                    Picker("Every", selection: $workspace.autoRefreshMinutes) {
                        Text("Off").tag(0); Text("15 min").tag(15); Text("30 min").tag(30)
                        Text("1 hour").tag(60); Text("4 hours").tag(240)
                    }.labelsHidden().frame(maxWidth: 110)
                    if let last = workspace.lastAutoRefresh {
                        Text("Last \(last, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.secondary)
                    }
                }.padding(4)
            }
            GroupBox("Follow a feed") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("https://…/feed.xml", text: $newURL).onSubmit(add)
                    TextField("Group (optional)", text: $newGroup).onSubmit(add)
                    Button("Follow", systemImage: "plus", action: add)
                        .disabled(busy || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    Button("Suggested feeds…", systemImage: "sparkles") { showSuggestions = true }.controlSize(.small)
                    HStack {
                        Button("Import OPML…", action: importOPML)
                        Button("Export OPML…", action: exportOPML).disabled(library.subscriptions.isEmpty)
                    }.controlSize(.small).lineLimit(1).minimumScaleFactor(0.8)
                    if !workspace.lastError.isEmpty { Text(workspace.lastError).font(.caption).foregroundStyle(.red) }
                    if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }.padding(4)
            }
        }.padding(.trailing, 8)
    }

    private var suggestionsSheet: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Suggested public-interest feeds").font(.headline)
            Text("Starting points only — nothing is followed until you choose it. PlateWatch keeps each publisher's title, link and a short summary, and always links back to the original; it never re-hosts articles.")
                .font(.caption).foregroundStyle(.secondary)
            List(RSSSuggestion.catalogue) { s in
                let following = library.subscriptions.contains { $0.url == s.url }
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.title).fontWeight(.medium)
                        Text("\(s.publisher) · \(s.group)").font(.caption).foregroundStyle(.secondary)
                        Text(s.about).font(.caption)
                        Text("Checked \(s.lastChecked)").font(.caption2).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(following ? "Following" : "Follow") {
                        Task { _ = await workspace.subscribeToFeed(urlText: s.url.absoluteString, title: s.title, group: s.group) }
                    }.disabled(following)
                }.padding(.vertical, 2)
            }
            HStack { Spacer(); Button("Done") { showSuggestions = false }.keyboardShortcut(.defaultAction) }
        }.padding().frame(width: 520, height: 440)
    }

    private func add() {
        busy = true
        Task {
            let ok = await workspace.subscribeToFeed(urlText: newURL, group: newGroup)
            if ok { newURL = "" }
            busy = false
        }
    }

    private func importOPML() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "opml") ?? .xml, .xml]
        guard panel.runModal() == .OK, let url = panel.url, let data = try? Data(contentsOf: url) else { return }
        let added = workspace.importOPML(data)
        notice = added == 0 ? "No new feeds found in that file." : "Added \(added) feed\(added == 1 ? "" : "s"). Refreshing…"
        Task { await workspace.refreshAllFeeds() }
    }

    private func exportOPML() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "platewatch-feeds.opml"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? OPML.export(library.subscriptions).write(to: url, atomically: true, encoding: .utf8)
    }

    @ViewBuilder private func feedRow(_ sub: RSSSubscription) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                Text(sub.title).lineLimit(1)
                if workspace.refreshingFeeds.contains(sub.id) { ProgressView().controlSize(.mini) }
            }
            if let err = sub.lastError { Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2) }
            else if let at = sub.lastFetchedAt { Text("Updated \(at, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.secondary) }
        }
        .badge(library.unreadCount(for: sub.id))
        .tag(Scope.feed(sub.id))
        .contextMenu {
            Button("Refresh") { Task { await workspace.refreshFeed(sub.id) } }
            Button("Mark all read") { workspace.rss.markAllRead(feed: sub.id) }
            Menu("Group") {
                ForEach(library.groups, id: \.self) { g in
                    Button(g) { workspace.rss.setGroup(g, for: sub.id) }
                }
                Button("New group…") { promptGroup(for: sub) }
                if !sub.group.isEmpty { Button("Remove from group") { workspace.rss.setGroup("", for: sub.id) } }
            }
            Divider()
            Button("Unfollow", role: .destructive) {
                if scope == .feed(sub.id) { scope = .all }
                workspace.rss.unsubscribe(sub.id)
            }
        }
    }

    private func promptGroup(for sub: RSSSubscription) {
        let alert = NSAlert()
        alert.messageText = "Group for “\(sub.title)”"
        alert.informativeText = "Groups keep related feeds together, e.g. Courts or Agency releases."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        field.stringValue = sub.group
        alert.accessoryView = field
        alert.addButton(withTitle: "Set group"); alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn { workspace.rss.setGroup(field.stringValue, for: sub.id) }
    }

    private func markScopeRead() {
        switch scope {
        case .all: workspace.rss.markAllRead()
        case .feed(let id): workspace.rss.markAllRead(feed: id)
        case .group(let g): workspace.rss.markAllRead(inGroup: g)
        }
    }

    // MARK: item list

    private var list: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Picker("Show", selection: $filter) {
                    Text("All").tag(RSSLibrary.Filter.all)
                    Text("Unread").tag(RSSLibrary.Filter.unread)
                    Text("Starred").tag(RSSLibrary.Filter.starred)
                }.pickerStyle(.segmented).labelsHidden()
                Button("Refresh", systemImage: "arrow.clockwise") {
                    busy = true
                    Task {
                        switch scope {
                        case .feed(let id): await workspace.refreshFeed(id)
                        case .group(let g): for id in library.feedIDs(inGroup: g) { await workspace.refreshFeed(id) }
                        case .all: await workspace.refreshAllFeeds()
                        }
                        busy = false
                    }
                }.labelStyle(.iconOnly).disabled(busy || library.subscriptions.isEmpty).help("Refresh")
                Button("Mark all read", systemImage: "checkmark.circle") { markScopeRead() }
                    .labelStyle(.iconOnly).help("Mark all read")
            }
            TextField("Search titles and summaries", text: $query).textFieldStyle(.roundedBorder)
            if items.isEmpty {
                ContentUnavailableView(library.subscriptions.isEmpty ? "No feeds yet" : "Nothing to show",
                                       systemImage: "dot.radiowaves.up.forward",
                                       description: Text(library.subscriptions.isEmpty
                                           ? "Follow an agency, court or news RSS/Atom feed (https only) to read it here."
                                           : "Try another filter or refresh."))
            } else {
                List(items, selection: $itemSelection) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 4) {
                            if !item.isRead { Circle().fill(.tint).frame(width: 7, height: 7).accessibilityLabel("Unread") }
                            if item.isStarred { Image(systemName: "star.fill").foregroundStyle(.yellow).imageScale(.small).accessibilityLabel("Starred") }
                            Text(item.title).fontWeight(item.isRead ? .regular : .semibold).lineLimit(2)
                        }
                        HStack {
                            if scope.feedID == nil, let name = library.subscriptions.first(where: { $0.id == item.feedID })?.title {
                                Text(name).lineLimit(1)
                            }
                            if let d = item.publishedAt { Text(d, format: .dateTime.month().day().year()) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.tag(item.id)
                }
                .onChange(of: itemSelection) { _, id in readerNotice = ""; if let id { workspace.rss.setRead(true, itemIDs: [id]) } }
            }
        }.padding(.horizontal, 8)
    }

    // MARK: reader

    @ViewBuilder private var reader: some View {
        if let item = selectedItem {
            let feed = library.subscriptions.first { $0.id == item.feedID }
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title).font(.title3.bold()).textSelection(.enabled)
                    HStack(spacing: 8) {
                        if let name = feed?.title { Text(name) }
                        if let a = item.author { Text("· \(a)") }
                        if let d = item.publishedAt { Text("· \(d, format: .dateTime.month().day().year())") }
                    }.font(.caption).foregroundStyle(.secondary)
                    if item.summary.isEmpty {
                        Text("This feed entry has no summary. Open the original to read it.").foregroundStyle(.secondary)
                    } else {
                        Text(item.summary).textSelection(.enabled)
                    }
                    if let link = item.link {
                        Text(link.absoluteString).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    HStack {
                        if let link = item.link { Button("Open original", systemImage: "safari") { NSWorkspace.shared.open(link) } }
                        Button(item.isStarred ? "Unstar" : "Star", systemImage: item.isStarred ? "star.slash" : "star") { workspace.rss.toggleStar(item.id) }
                        Button(item.isRead ? "Mark unread" : "Mark read", systemImage: "circle") { workspace.rss.setRead(!item.isRead, itemIDs: [item.id]) }
                    }
                    Divider()
                    Text("Entry text is the publisher's wording, shown as plain text. It is not verified.").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("Save for review", systemImage: "tray.and.arrow.down") {
                            readerNotice = workspace.saveFeedItemForReview(item) ? "Saved as a pending candidate in Court & lists." : "Already saved."
                        }
                        Button("Draft request from this…", systemImage: "doc.text") { startRequest(from: item, feed: feed) }
                    }
                    Text("Saving creates a pending, cited news candidate. Nothing is accepted, linked to a person or published automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !readerNotice.isEmpty { Text(readerNotice).font(.caption).foregroundStyle(.secondary) }
                }.padding()
            }
        } else {
            ContentUnavailableView("Select an entry", systemImage: "newspaper",
                                   description: Text("Feeds are fetched over https, read-only, and stay on this Mac."))
        }
    }

    /// Adds a tracker draft whose subject quotes the entry; the user completes agency/state and files it themselves.
    private func startRequest(from item: RSSItem, feed: RSSSubscription?) {
        let subject = "Records related to: \(item.title)"
        let r = FOIARequest(agencyName: feed?.title ?? "Agency", stateCode: nil, subject: String(subject.prefix(200)),
                            body: "Source: \(item.link?.absoluteString ?? "feed entry")\nUse the FOIA draft tab to write the request, then paste it here when you file.")
        workspace.tracker.upsert(r)
        readerNotice = "Added a draft to Requests — set the agency and state there."
    }
}

private extension RecordsFeedsView.Scope {
    var feedID: UUID? { if case .feed(let id) = self { id } else { nil } }
    var groupName: String? { if case .group(let g) = self { g } else { nil } }
}

/// A thin draggable divider that resizes the column to its left; width persists via the caller's AppStorage.
private struct ColumnResizeHandle: View {
    @Binding var width: Double
    let range: ClosedRange<Double>
    let label: String
    @State private var startWidth: Double?

    var body: some View {
        Rectangle().fill(Color.secondary.opacity(0.25)).frame(width: 1)
            .padding(.horizontal, 4)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
            .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
                .onChanged { value in
                    let base = startWidth ?? width
                    startWidth = base
                    width = min(max(base + value.translation.width, range.lowerBound), range.upperBound)
                }
                .onEnded { _ in startWidth = nil })
            .accessibilityElement()
            .accessibilityLabel(label)
            .accessibilityValue("\(Int(width)) points")
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment: width = min(width + 20, range.upperBound)
                case .decrement: width = max(width - 20, range.lowerBound)
                @unknown default: break
                }
            }
    }
}
