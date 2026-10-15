import FeedIngest
import SwiftUI

struct FeedsPane: View {
    enum Tab: String, CaseIterable, Identifiable { case all = "All feeds", favorites = "Favorites", blocked = "Blocked"; var id: String { rawValue } }
    enum SortKey: String, CaseIterable, Identifiable { case state = "State", name = "Name", host = "Host", location = "Location", status = "Status"; var id: String { rawValue } }

    @ObservedObject var hub: HubController
    let isActive: Bool
    var onOpenLive: () -> Void
    @ObservedObject private var favorites: FeedFavorites
    @ObservedObject private var runner: FeedRunner
    @State private var catalogue: FeedCatalogue?
    @State private var tab: Tab = .all
    @State private var query = ""
    @State private var hostFilter = ""
    @State private var statusFilter: FeedRunner.StatusKind?
    @State private var sortKey: SortKey = .state
    @State private var ascending = true
    @State private var favoritesFirst = false
    @State private var termsExpanded = false
    @State private var reviewing: FeedHostSummary?
    @State private var selected: Set<UUID> = []

    init(hub: HubController, isActive: Bool, onOpenLive: @escaping () -> Void) {
        self.hub = hub
        self.isActive = isActive
        self.onOpenLive = onOpenLive
        _favorites = ObservedObject(wrappedValue: hub.favorites)
        _runner = ObservedObject(wrappedValue: hub.feedRunner)
    }

    private var hosts: [FeedHostSummary] { catalogue?.hosts() ?? [] }
    private var needReview: [FeedHostSummary] { hosts.filter { $0.confirmedCount < $0.totalCount } }
    private var totalCount: Int { catalogue?.sources.count ?? 0 }

    /// Search (every word must match name, host, area or attribution) → filters → sort.
    private var rows: [PublicFeedSource] {
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
            case .status: return hub.feedRunner.state(of: s).kind.rawValue + " " + s.name.lowercased()
            }
        }
        list.sort { a, b in
            if favoritesFirst, favorites.contains(a.id) != favorites.contains(b.id) { return favorites.contains(a.id) }
            return ascending ? key(a) < key(b) : key(a) > key(b)
        }
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !needReview.isEmpty { termsBanner }
            HStack {
                Picker("", selection: $tab) {
                    Text("All feeds (\(totalCount))").tag(Tab.all)
                    Text("★ Favorites (\(favorites.ids.subtracting(favorites.blockedIDs).count))").tag(Tab.favorites)
                    Text("⦸ Blocked (\(favorites.blockedIDs.count))").tag(Tab.blocked)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 490)
                Spacer()
                FeedStatusRow(runner: hub.feedRunner)
                Menu("Add cameras") {
                    Button("Texas — Austin traffic cameras (about 820)") { Task { await hub.importAustinCameras(); reload() } }
                    ForEach(HubController.OpenCatalogue.allCases) { c in
                        Button(c.rawValue) { Task { await hub.importCatalogue(c); reload() } }
                    }
                }
                Button("Reveal feeds.json") { hub.revealFeedsFile() }
            }
            if !hub.importStatus.isEmpty { Text(hub.importStatus).font(.caption).foregroundStyle(.secondary) }
            if tab != .favorites { controls }
            if tab == .favorites { favoritesGrid } else { listAndPreview }
            if tab != .favorites {
                Text(tab == .blocked
                     ? "Blocked cameras are saved on this Mac and receive no polling or preview requests. Use ↶ to unblock."
                     : "\(rows.count) of \(totalCount) cameras. Use ☆ to favorite or ⦸ to block a missing feed. Requests share a one-per-host-per-second budget.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: tab) { _, value in
            if value == .blocked { query = ""; hostFilter = ""; statusFilter = nil }
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
            HStack(spacing: 10) { sortControl; Spacer() }
        }
    }

    private var searchControl: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, host or area", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(6).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 300)
        }
        .help("Every search word must match the camera's name, host, area or attribution")
    }

    private var sourceControl: some View {
        Picker("Source", selection: $hostFilter) {
            Text("All sources").tag("")
            ForEach(hosts, id: \.host) { Text("\($0.host) (\($0.totalCount))").tag($0.host) }
        }.frame(maxWidth: 260).help("Filter cameras by their image host")
    }

    private var statusControl: some View {
        Picker("Status", selection: $statusFilter) {
            Text("Any status").tag(FeedRunner.StatusKind?.none)
            ForEach(FeedRunner.StatusKind.allCases) { Text($0.rawValue).tag(FeedRunner.StatusKind?.some($0)) }
        }.frame(maxWidth: 200).help("Filter by terms, robots policy, polling or local block status")
    }

    private var sortControl: some View {
        HStack(spacing: 10) {
            Picker("Sort", selection: $sortKey) { ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 150)
            Button { ascending.toggle() } label: { Image(systemName: ascending ? "arrow.up" : "arrow.down") }
                .help(ascending ? "Ascending; click for descending" : "Descending; click for ascending")
            Toggle("Favorites first", isOn: $favoritesFirst).toggleStyle(.checkbox)
                .help("Place starred cameras before the selected sort order")
        }
    }

    private var listAndPreview: some View {
        HSplitView {
            Table(rows, selection: $selected) {
                TableColumn("") { s in
                    Button { favorites.toggle(s.id) } label: {
                        Image(systemName: favorites.contains(s.id) ? "star.fill" : "star")
                            .foregroundStyle(favorites.contains(s.id) ? Color.yellow : Color.secondary)
                    }.buttonStyle(.plain).help(favorites.contains(s.id) ? "Remove from favorites" : "Add to favorites")
                }.width(28)
                TableColumn("") { s in
                    FeedBlockButton(hub: hub, preferences: favorites, source: s)
                }.width(28)
                TableColumn("Camera") { Text($0.name) }
                TableColumn("Host") { Text($0.url.host ?? "") }
                TableColumn("Location") { Text($0.geohash6.isEmpty ? "unknown" : $0.geohash6).monospaced() }.width(70)
                TableColumn("Status") { s in
                    let state = hub.feedRunner.state(of: s)
                    Label(state.text, systemImage: state.icon).foregroundStyle(state.color)
                }
            }
            .frame(minWidth: 460)
            CameraPreviewPanel(hub: hub, favorites: favorites, isActive: isActive, onOpenLive: onOpenLive,
                               source: selected.first.flatMap { id in catalogue?.sources.first { $0.id == id } })
                .frame(minWidth: 300, idealWidth: 380)
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
    private func reload() { catalogue = try? FeedCatalogue.load(from: hub.feedsFile) }
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
                }
                Text(source.url.host ?? "").font(.caption).foregroundStyle(.secondary).monospaced()
                Label("Snapshot camera · refresh ≥ \(Int(source.refreshInterval)) seconds", systemImage: "photo")
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
