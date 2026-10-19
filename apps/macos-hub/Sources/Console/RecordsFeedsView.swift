import AccountabilityKit
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// RSS/Atom reader for public-records sources: agency release feeds, court and news feeds. Read-only and local —
/// feed text is untrusted data shown as plain text, and nothing is filed, accepted or published from here.
struct RecordsFeedsView: View {
    @State private var workspace = RecordsWorkspace.shared
    @State private var feedSelection: UUID?       // nil = all feeds
    @State private var itemSelection: String?
    @State private var filter: RSSLibrary.Filter = .all
    @State private var query = ""
    @State private var newURL = ""
    @State private var newGroup = ""
    @State private var busy = false
    @State private var notice = ""

    private var library: RSSLibrary { workspace.rss }
    private var items: [RSSItem] { library.visible(feed: feedSelection, filter: filter, query: query) }
    private var selectedItem: RSSItem? { library.items.first { $0.id == itemSelection } }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            sidebar.frame(width: 250)
            Divider()
            list.frame(minWidth: 300, idealWidth: 340, maxWidth: 400)
            Divider()
            reader.frame(maxWidth: .infinity)
        }
    }

    // MARK: feeds

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            List(selection: $feedSelection) {
                Label("All feeds", systemImage: "tray.2").badge(library.unreadCount()).tag(UUID?.none)
                ForEach(library.subscriptions) { sub in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack {
                            Text(sub.title).lineLimit(1)
                            if workspace.refreshingFeeds.contains(sub.id) { ProgressView().controlSize(.mini) }
                        }
                        if let err = sub.lastError { Text(err).font(.caption2).foregroundStyle(.red).lineLimit(2) }
                        else if let at = sub.lastFetchedAt { Text("Updated \(at, format: .relative(presentation: .named))").font(.caption2).foregroundStyle(.secondary) }
                    }
                    .badge(library.unreadCount(for: sub.id))
                    .tag(UUID?.some(sub.id))
                    .contextMenu {
                        Button("Refresh") { Task { await workspace.refreshFeed(sub.id) } }
                        Button("Mark all read") { workspace.rss.markAllRead(feed: sub.id) }
                        Divider()
                        Button("Unfollow", role: .destructive) {
                            if feedSelection == sub.id { feedSelection = nil }
                            workspace.rss.unsubscribe(sub.id)
                        }
                    }
                }
            }
            GroupBox("Follow a feed") {
                VStack(alignment: .leading, spacing: 6) {
                    TextField("https://…/feed.xml", text: $newURL).onSubmit(add)
                    Button("Follow", systemImage: "plus", action: add)
                        .disabled(busy || newURL.trimmingCharacters(in: .whitespaces).isEmpty)
                    HStack {
                        Button("Import OPML…", action: importOPML)
                        Button("Export…", action: exportOPML).disabled(library.subscriptions.isEmpty)
                    }.controlSize(.small)
                    if !workspace.lastError.isEmpty { Text(workspace.lastError).font(.caption).foregroundStyle(.red) }
                    if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
                }.padding(4)
            }
        }.padding(.trailing, 8)
    }

    private func add() {
        busy = true
        Task {
            let ok = await workspace.subscribeToFeed(urlText: newURL)
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
                        if let id = feedSelection { await workspace.refreshFeed(id) } else { await workspace.refreshAllFeeds() }
                        busy = false
                    }
                }.labelStyle(.iconOnly).disabled(busy || library.subscriptions.isEmpty).help("Refresh")
                Button("Mark all read", systemImage: "checkmark.circle") { workspace.rss.markAllRead(feed: feedSelection) }
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
                            if feedSelection == nil, let name = library.subscriptions.first(where: { $0.id == item.feedID })?.title {
                                Text(name).lineLimit(1)
                            }
                            if let d = item.publishedAt { Text(d, format: .dateTime.month().day().year()) }
                        }.font(.caption).foregroundStyle(.secondary)
                    }.tag(item.id)
                }
                .onChange(of: itemSelection) { _, id in if let id { workspace.rss.setRead(true, itemIDs: [id]) } }
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
                            notice = workspace.saveFeedItemForReview(item) ? "Saved as a pending candidate in Court & lists." : "Already saved."
                        }
                        Button("Draft request from this…", systemImage: "doc.text") { startRequest(from: item, feed: feed) }
                    }
                    Text("Saving creates a pending, cited news candidate. Nothing is accepted, linked to a person or published automatically.")
                        .font(.caption).foregroundStyle(.secondary)
                    if !notice.isEmpty { Text(notice).font(.caption).foregroundStyle(.secondary) }
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
        notice = "Added a draft to Requests — set the agency and state there."
    }
}
