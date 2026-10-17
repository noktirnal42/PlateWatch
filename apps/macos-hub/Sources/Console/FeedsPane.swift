import FeedIngest
import SwiftUI

struct FeedsPane: View {

    let hub: HubController
    let isActive: Bool
    var onOpenLive: () -> Void
    @ObservedObject private var favorites: FeedFavorites
    @ObservedObject private var runner: FeedRunner
    @ObservedObject private var browser: FeedBrowserState
    @State private var catalogue: FeedCatalogue?
    @State private var termsExpanded = false
    @State private var reviewing: FeedHostSummary?

    init(hub: HubController, isActive: Bool, onOpenLive: @escaping () -> Void) {
        self.hub = hub
        self.isActive = isActive
        self.onOpenLive = onOpenLive
        _favorites = ObservedObject(wrappedValue: hub.favorites)
        _runner = ObservedObject(wrappedValue: hub.feedRunner)
        _browser = ObservedObject(wrappedValue: hub.feedBrowserState)
    }

    private var tab: FeedBrowserState.Tab { browser.tab }
    private var query: String { browser.query }
    private var hostFilter: String { browser.hostFilter }
    private var statusFilter: FeedRunner.StatusKind? { browser.statusFilter }
    private var sortKey: FeedBrowserState.SortKey { browser.sortKey }
    private var ascending: Bool { browser.ascending }
    private var favoritesFirst: Bool { browser.favoritesFirst }
    private var selected: Set<UUID> { browser.selected }

    @State private var hosts: [FeedHostSummary] = []
    private var needReview: [FeedHostSummary] { hosts.filter { $0.confirmedCount < $0.totalCount } }
    private var totalCount: Int { catalogue?.sources.count ?? 0 }

    /// Search (every word must match name, host, area or attribution) → filters → sort.
    /// Filtering and sorting thousands of cameras is expensive; it runs only when an input changes (`refreshRows`), never per render.
    private func computeRows() -> [PublicFeedSource] {
        var list = catalogue?.sources ?? []
        list = list.filter { tab == .blocked ? favorites.isBlocked($0.id) : !favorites.isBlocked($0.id) }
        if tab == .favorites { list = list.filter { favorites.contains($0.id) } }
        if !hostFilter.isEmpty { list = list.filter { $0.url.host == hostFilter } }
        if let statusFilter { list = list.filter { hub.feedRunner.state(of: $0).kind == statusFilter } }
        let words = query.lowercased().split(separator: " ").map(String.init)
        if !words.isEmpty {
            list = list.filter { s in
                let hay = "\(s.name) \(s.url.host ?? "") \(s.geohash6) \(s.state ?? "") \(s.terms.attribution)".lowercased()
                return words.allSatisfy(hay.contains)
            }
        }
        func key(_ s: PublicFeedSource) -> String {
            switch sortKey {
            case .state: return (s.state ?? "zz") + " " + s.name.lowercased()
            case .name: return s.name.lowercased()
            case .host: return (s.url.host ?? "") + " " + s.name.lowercased()
            case .location: return s.geohash6 + " " + s.name.lowercased()
            case .status: return runner.state(of: s).kind.rawValue + " " + s.name.lowercased()
            }
        }
        // Decorate once (one key string per camera) instead of rebuilding keys inside every comparison.
        let ascending = self.ascending, favoritesFirst = self.favoritesFirst
        var decorated = list.map { (fav: favoritesFirst && favorites.contains($0.id), key: key($0), source: $0) }
        decorated.sort { a, b in
            if a.fav != b.fav { return a.fav }
            return ascending ? a.key < b.key : a.key > b.key
        }
        return decorated.map(\.source)
    }

    @State private var rows: [PublicFeedSource] = []
    private func refreshRows() { rows = computeRows() }

    var body: some View { observedContent }

    private var contentWithFilters: some View {
        feedContent
            .onChange(of: query) { _, _ in refreshRows() }
            .onChange(of: hostFilter) { _, _ in refreshRows() }
            .onChange(of: statusFilter) { _, _ in refreshRows() }
            .onChange(of: sortKey) { _, _ in refreshRows() }
            .onChange(of: ascending) { _, _ in refreshRows() }
            .onChange(of: favoritesFirst) { _, _ in refreshRows() }
    }

    private var feedContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !needReview.isEmpty { termsBanner }
            HStack {
                Picker("", selection: Binding(get: { browser.tab }, set: { browser.tab = $0; browser.save() })) {
                    Text("All feeds (\(totalCount))").tag(FeedBrowserState.Tab.all)
                    Text("★ Favorites (\(favorites.ids.subtracting(favorites.blockedIDs).count))").tag(FeedBrowserState.Tab.favorites)
                    Text("⦸ Blocked (\(favorites.blockedIDs.count))").tag(FeedBrowserState.Tab.blocked)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 490)
                Spacer()
                Menu("Add cameras") {
                    Button("Texas — Austin traffic cameras (about 820)") { Task { await hub.importAustinCameras(); reload() } }
                    ForEach(HubController.OpenCatalogue.allCases) { c in
                        Button(c.rawValue) { Task { await hub.importCatalogue(c); reload() } }
                    }
                }
                Label("\(favorites.watchedIDs.count) watched", systemImage: "eye.fill")
                    .foregroundStyle(.secondary)
                    .help("Cameras selected for background analysis")
                Button("Watch \(favorites.ids.count) favorites") { hub.watchAllFavorites() }
                    .disabled(favorites.ids.isEmpty)
                    .help("Analyse all starred cameras in the background")
                Button("Reveal feeds.json") { hub.revealFeedsFile() }
            }
            FeedStatusRow(runner: hub.feedRunner)
                .font(.caption).foregroundStyle(.secondary)
            if tab == .favorites {
                HStack(spacing: 10) {
                    Label("Favorites scope: showing \(favorites.ids.count) starred feeds; the full catalogue has \(totalCount.formatted()) sources.", systemImage: "star.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Show all feeds") { browser.resetView(); reload() }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .accessibilityHint("Clears the persisted Favorites scope and all feed filters")
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Favorites scope. Showing \(favorites.ids.count) starred feeds out of \(totalCount) total. Show all feeds button available.")
            }
            if tab == .all && totalCount > favorites.watchedIDs.count {
                Label {
                    Text("The catalogue is fully loaded. Background analysis runs only for watched cameras (\(favorites.watchedIDs.count) selected); idle cameras remain available for preview or Live.")
                } icon: {
                    Image(systemName: "info.circle.fill")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Catalogue loaded. Background analysis runs only for watched cameras. \(favorites.watchedIDs.count) cameras selected.")
                .help("Use the eye column or Watch favorites to select cameras for background analysis. This avoids polling thousands of public endpoints at once.")
            }
            if !hub.importStatus.isEmpty { Text(hub.importStatus).font(.caption).foregroundStyle(.secondary) }
            if tab != .favorites { controls }
            if tab == .favorites { favoritesGrid } else { listAndPreview }
            if tab != .favorites {
                Text(tab == .blocked
                     ? "Blocked cameras are saved on this Mac and receive no polling or preview requests. Use ↶ to unblock."
                     : "\(rows.count) of \(totalCount) cameras · \(favorites.watchedIDs.count) watched. Use the eye to choose background analysis, ☆ to favorite, or ⦸ to block. Requests share a one-per-host-per-second budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
    }

    private var observedContent: some View {
        contentWithFilters
        .onAppear(perform: reload)
        .onChange(of: catalogue?.sources.count) { _, _ in refreshRows() }
        .onChange(of: favorites.ids) { _, _ in refreshRows() }
        .onChange(of: favorites.blockedIDs) { _, _ in refreshRows() }
        .onChange(of: favorites.watchedIDs) { _, _ in refreshRows() }
        // Camera statuses only matter to the list when it is filtered or sorted by status.
        .onChange(of: runner.stateRevision) { _, _ in if statusFilter != nil || sortKey == .status { refreshRows() } }
        .onChange(of: tab) { _, _ in refreshRows() }
        .onChange(of: tab) { _, value in
            if value == .blocked { browser.query = ""; browser.hostFilter = ""; browser.statusFilter = nil; browser.save() }
        }
        .onChange(of: hub.importStatus) { _, _ in reload() }
        .sheet(item: Binding(get: { reviewing.map(HostBox.init) }, set: { reviewing = $0?.host })) { box in
            TermsReviewSheet(hub: hub, host: box.host, sample: catalogue?.sources.first { $0.url.host == box.host.host }) {
                reviewing = nil; reload()
            }
        }
    }

    // MARK: Pieces

    private var termsBanner: some View {
        DisclosureGroup(isExpanded: $termsExpanded) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Imports add metadata only. Review and confirm each image host's terms before polling.")
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(needReview, id: \.host) { h in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.host).monospaced()
                                Text("\(h.totalCount - h.confirmedCount) cameras waiting").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Review terms…") { reviewing = h }
                        }
                        Divider()
                    }
                }.padding(.top, 8)
            }.frame(maxHeight: 220)
        } label: {
            Label("\(needReview.count) hosts awaiting terms review · \(needReview.reduce(0) { $0 + $1.totalCount - $1.confirmedCount }) cameras inactive", systemImage: "hand.raised")
                .font(.callout.weight(.medium))
        }
        .padding(12)
        .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .help("Expand to review newly imported image hosts; no camera is polled before approval")
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) { searchControl; sourceControl; statusControl }
            HStack(spacing: 10) {
                sortControl
                Spacer()
                Text("\(rows.count.formatted()) shown · \(totalCount.formatted()) total")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Reset view") { browser.resetView(); reload() }
                    .help("Show every catalogue camera, clear search and filters, and reload the list")
                    .accessibilityLabel("Reset camera catalogue view and reload every feed")
            }
        }
    }

    private var searchControl: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, host or area", text: Binding(get: { browser.query }, set: { browser.query = $0; browser.save() })).textFieldStyle(.plain)
                if !query.isEmpty { Button { browser.query = ""; browser.save() } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(6).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 300)
        }
        .help("Every search word must match the camera's name, host, area or attribution")
    }

    private var sourceControl: some View {
        Picker("Source", selection: Binding(get: { browser.hostFilter }, set: { browser.hostFilter = $0; browser.save() })) {
            Text("All sources").tag("")
            ForEach(hosts, id: \.host) { Text("\($0.host) (\($0.totalCount))").tag($0.host) }
        }.frame(maxWidth: 260).help("Filter cameras by their image host")
    }

    private var statusControl: some View {
        Picker("Status", selection: Binding(get: { browser.statusFilter }, set: { browser.statusFilter = $0; browser.save() })) {
            Text("Any status").tag(FeedRunner.StatusKind?.none)
            ForEach(FeedRunner.StatusKind.allCases) { Text($0.rawValue).tag(FeedRunner.StatusKind?.some($0)) }
        }.frame(maxWidth: 200).help("Filter by terms, robots policy, polling or local block status")
    }

    private var sortControl: some View {
        HStack(spacing: 10) {
            Picker("Sort", selection: Binding(get: { browser.sortKey }, set: { browser.sortKey = $0; browser.save() })) { ForEach(FeedBrowserState.SortKey.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 150)
            Button { browser.ascending.toggle(); browser.save() } label: { Image(systemName: ascending ? "arrow.up" : "arrow.down") }
                .help(ascending ? "Ascending; click for descending" : "Descending; click for ascending")
            Toggle("Favorites first", isOn: Binding(get: { browser.favoritesFirst }, set: { browser.favoritesFirst = $0; browser.save() })).toggleStyle(.checkbox)
                .help("Place starred cameras before the selected sort order")
        }
    }

    private var listAndPreview: some View {
        HSplitView {
            Table(rows, selection: Binding(get: { browser.selected }, set: { browser.selected = $0; browser.save() })) {
                TableColumn("") { s in
                    Button { favorites.toggle(s.id) } label: {
                        Image(systemName: favorites.contains(s.id) ? "star.fill" : "star")
                            .foregroundStyle(favorites.contains(s.id) ? Color.yellow : Color.secondary)
                    }.buttonStyle(.plain).help(favorites.contains(s.id) ? "Remove from favorites" : "Add to favorites")
                }.width(28)
                TableColumn("") { s in
                    FeedBlockButton(hub: hub, preferences: favorites, source: s)
                }.width(28)
                TableColumn("Watch") { source in
                    VStack(spacing: 2) {
                        FeedWatchButton(hub: hub, favorites: favorites, source: source)
                        if let count = hub.processorCount(for: source.id), count > 0 {
                            Label("\(count)", systemImage: "person.2")
                                .font(.caption2.monospacedDigit()).foregroundStyle(.tint)
                                .help("\(count) active processing console(s) selected this feed")
                                .accessibilityLabel("\(count) active processing console(s) selected this feed")
                        }
                    }
                }.width(42)
                TableColumn("Camera / source") { source in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.name).lineLimit(1)
                        Text(source.url.host ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .padding(.vertical, 3)
                    .help("\(source.name)\n\(source.url.host ?? "")\nArea: \(source.geohash6)")
                }.width(min: 120, ideal: 180, max: 360)
                TableColumn("Status") { s in
                    let state = hub.feedRunner.state(of: s)
                    Label(state.text, systemImage: state.icon).foregroundStyle(state.color).lineLimit(1).help(state.text)
                }.width(120)
            }
            .frame(minWidth: 430)
            CameraPreviewPanel(hub: hub, favorites: favorites, isActive: isActive, onOpenLive: onOpenLive,
                               source: selected.first.flatMap { id in catalogue?.sources.first { $0.id == id } })
                .frame(minWidth: 260, idealWidth: 300, maxWidth: 380)
        }
    }

    private var favoritesGrid: some View {
        let favs = (catalogue?.sources ?? []).filter { favorites.contains($0.id) && !favorites.isBlocked($0.id) }.sorted { $0.name < $1.name }
        return Group {
            if favs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No favorites yet").font(.headline)
                    Text("Click ☆ in All feeds to pin a camera here. Blocked favorites are hidden; unblock them in the Blocked tab to restore them.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(favs) { FavoriteTile(hub: hub, favorites: favorites, source: $0, isActive: isActive, onOpenLive: onOpenLive) }
                    }.padding(.bottom, 8)
                }
            }
        }
    }

    private struct HostBox: Identifiable { let host: FeedHostSummary; var id: String { host.host } }
    private func reload() {
        catalogue = try? FeedCatalogue.load(from: hub.feedsFile)
        // Grouping 8,000+ URLs on every frame/status notification starves the main thread.
        hosts = catalogue?.hosts() ?? []
        refreshRows()
    }
}

/// A favorite camera: live thumbnail (refreshed no faster than every 30 s, and never faster than the source's own interval).
struct FavoriteTile: View {
    @ObservedObject var hub: HubController
    @ObservedObject var favorites: FeedFavorites
    let source: PublicFeedSource
    let isActive: Bool
    var onOpenLive: () -> Void
    @State private var image: NSImage?
    @State private var message = ""
    @State private var policyRetryDelay: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { Text(message.isEmpty ? "Loading…" : message).font(.caption).foregroundStyle(.secondary).padding(8) }
            }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(source.name).font(.callout.bold()).lineLimit(1)
                if let state = source.state {
                    Text(state).font(.caption2.bold())
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(.quaternary, in: Capsule())
                        .help("State recorded by the catalogue import")
                }
                Spacer()
                Button { favorites.toggle(source.id) } label: { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    .buttonStyle(.plain).help("Remove from favorites")
                    .accessibilityLabel("Remove \(source.name) from favorites")
                FeedBlockButton(hub: hub, preferences: favorites, source: source)
                FeedWatchButton(hub: hub, favorites: favorites, source: source)
            }
            Button("Open in Live", systemImage: "play.rectangle") {
                hub.openFeedInLive(source); onOpenLive()
            }.help("Open this camera's analysed snapshots in Live")
                .disabled(!source.mayBeAnalysed || favorites.isBlocked(source.id))
            Text(source.url.host ?? "").font(.caption2).foregroundStyle(.secondary).monospaced()
        }
        .task(id: "\(source.id)-\(isActive)") {
            guard isActive else { image = nil; return }
            while !Task.isCancelled {
                policyRetryDelay = nil
                do {
                    let data = try await hub.feedRunner.fetchPreview(of: source)
                    guard !Task.isCancelled, !favorites.isBlocked(source.id) else { return }
                    if let img = NSImage(data: data) { image = img; message = "" }
                    else { image = nil; message = "Image unavailable. Use ⦸ to block this camera." }
                } catch {
                    image = nil; message = error.localizedDescription
                    policyRetryDelay = (error as? FeedRunner.PreviewError)?.policyRetryDelay
                }
                try? await Task.sleep(for: .seconds(policyRetryDelay ?? max(source.refreshInterval, 30)))
            }
        }
    }
}

/// Shows the selected camera's current frame, refreshed no faster than the source's own interval.
struct CameraPreviewPanel: View {
    @ObservedObject var hub: HubController
    @ObservedObject var favorites: FeedFavorites
    let isActive: Bool
    var onOpenLive: () -> Void
    let source: PublicFeedSource?
    @State private var image: NSImage?
    @State private var fetchedAt: Date?
    @State private var message = ""
    @State private var policyRetryDelay: TimeInterval?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let source {
                HStack {
                    Text(source.name).font(.headline)
                    Spacer()
                    Button { favorites.toggle(source.id) } label: {
                        Image(systemName: favorites.contains(source.id) ? "star.fill" : "star")
                            .foregroundStyle(favorites.contains(source.id) ? Color.yellow : Color.secondary)
                    }.buttonStyle(.plain).help("Favorite")
                        .accessibilityLabel("Favorite \(source.name)")
                    FeedBlockButton(hub: hub, preferences: favorites, source: source)
                    FeedWatchButton(hub: hub, favorites: favorites, source: source)
                }
                Text(source.url.host ?? "").font(.caption).foregroundStyle(.secondary).monospaced()
                Label(source.kind == .hls ? "HLS video · sampled analysis" : "Snapshot camera · refresh ≥ \(Int(source.refreshInterval)) seconds", systemImage: source.kind == .hls ? "video" : "photo")
                    .font(.caption).foregroundStyle(.secondary)
                ZStack {
                    Rectangle().fill(.black.opacity(0.85))
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Text(message.isEmpty ? "Loading…" : message).foregroundStyle(.secondary).padding() }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                HStack {
                    if let fetchedAt { Text("Fetched \(fetchedAt, format: .dateTime.hour().minute().second())").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Refresh now") { Task { await load(source, retryFailedPolicy: true) } }
                        .disabled(favorites.isBlocked(source.id))
                }
                Button("Open in Live", systemImage: "play.rectangle") {
                    hub.openFeedInLive(source); onOpenLive()
                }
                .modifier(HubPrimaryAction())
                .help("Show this camera's analysed snapshots and vehicle overlays in Live")
                .disabled(!source.mayBeAnalysed || favorites.isBlocked(source.id))
                if !source.mayBeAnalysed {
                    Text("Confirm this host's terms (Review terms…) to view and poll its cameras.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Select a camera to see its current frame.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .task(id: source.map { "\($0.id)-\(favorites.isBlocked($0.id))-\(isActive)" }) {
            image = nil; fetchedAt = nil; message = ""
            guard isActive, let source else { return }
            guard !favorites.isBlocked(source.id) else { message = "Blocked on this Mac. Unblock this camera to view it again."; return }
            while !Task.isCancelled {
                await load(source)
                try? await Task.sleep(for: .seconds(policyRetryDelay ?? max(source.refreshInterval, 10)))
            }
        }
    }

    private func load(_ source: PublicFeedSource, retryFailedPolicy: Bool = false) async {
        policyRetryDelay = nil
        do {
            let data = try await hub.feedRunner.fetchPreview(of: source, retryFailedPolicy: retryFailedPolicy)
            guard !Task.isCancelled, !favorites.isBlocked(source.id), self.source?.id == source.id else { return }
            if let img = NSImage(data: data) { image = img; fetchedAt = Date(); message = "" }
            else { image = nil; message = "The camera returned an unavailable or unreadable image. You can block it using ⦸ above." }
        } catch {
            guard !Task.isCancelled, self.source?.id == source.id else { return }
            message = error.localizedDescription; image = nil
            policyRetryDelay = (error as? FeedRunner.PreviewError)?.policyRetryDelay
        }
    }
}

/// Reversible local exclusion; no terms changes and no change to the upstream camera.
struct FeedBlockButton: View {
    @ObservedObject var hub: HubController
    @ObservedObject var preferences: FeedFavorites
    let source: PublicFeedSource

    var body: some View {
        Button { hub.toggleFeedBlock(source.id) } label: {
            Image(systemName: preferences.isBlocked(source.id) ? "arrow.uturn.backward.circle" : "nosign")
                .foregroundStyle(preferences.isBlocked(source.id) ? Color.orange : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(preferences.isBlocked(source.id) ? "Unblock camera on this Mac" : "Block camera on this Mac (stops polling and previews)")
        .accessibilityLabel("\(preferences.isBlocked(source.id) ? "Unblock" : "Block") \(source.name)")
    }
}

/// Chooses whether this camera is analysed in the background. Unwatched
/// confirmed cameras stay idle; a feed open in Live is analysed while open
/// regardless of this toggle.
struct FeedWatchButton: View {
    @ObservedObject var hub: HubController
    @ObservedObject var favorites: FeedFavorites
    let source: PublicFeedSource

    var body: some View {
        Button { hub.toggleFeedWatch(source.id) } label: {
            Image(systemName: favorites.isWatched(source.id) ? "eye.fill" : "eye.slash")
                .foregroundStyle(favorites.isWatched(source.id) ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .help(favorites.isWatched(source.id) ? "Stop background analysis of this camera" : "Analyse this camera in the background")
        .accessibilityLabel("\(favorites.isWatched(source.id) ? "Stop watching" : "Watch") \(source.name)")
    }
}
