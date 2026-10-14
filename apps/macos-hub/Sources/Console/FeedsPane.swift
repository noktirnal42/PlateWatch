import FeedIngest
import SwiftUI

/// The person's starred cameras, persisted locally (UserDefaults) by camera id.
@MainActor
final class FeedFavorites: ObservableObject {
    @Published private(set) var ids: Set<UUID>
    private let key = "hubFavoriteFeeds"

    init() {
        ids = Set((UserDefaults.standard.stringArray(forKey: "hubFavoriteFeeds") ?? []).compactMap(UUID.init(uuidString:)))
    }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
    func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        UserDefaults.standard.set(ids.map(\.uuidString), forKey: key)
    }
}

struct FeedsPane: View {
    enum Tab: String, CaseIterable, Identifiable { case all = "All feeds", favorites = "Favorites"; var id: String { rawValue } }
    enum SortKey: String, CaseIterable, Identifiable { case name = "Name", host = "Host", location = "Location", status = "Status"; var id: String { rawValue } }

    @ObservedObject var hub: HubController
    @ObservedObject private var favorites: FeedFavorites
    @State private var catalogue: FeedCatalogue?
    @State private var tab: Tab = .all
    @State private var query = ""
    @State private var hostFilter = ""
    @State private var statusFilter: FeedRunner.StatusKind?
    @State private var sortKey: SortKey = .name
    @State private var ascending = true
    @State private var favoritesFirst = false
    @State private var reviewing: FeedHostSummary?
    @State private var selected: Set<UUID> = []

    init(hub: HubController) { self.hub = hub; _favorites = ObservedObject(wrappedValue: hub.favorites) }

    private var hosts: [FeedHostSummary] { catalogue?.hosts() ?? [] }
    private var needReview: [FeedHostSummary] { hosts.filter { $0.confirmedCount < $0.totalCount } }
    private var totalCount: Int { catalogue?.sources.count ?? 0 }

    /// Search (every word must match name, host, area or attribution) → filters → sort.
    private var rows: [PublicFeedSource] {
        var list = catalogue?.sources ?? []
        if tab == .favorites { list = list.filter { favorites.contains($0.id) } }
        if !hostFilter.isEmpty { list = list.filter { $0.url.host == hostFilter } }
        if let statusFilter { list = list.filter { hub.feedRunner.state(of: $0).kind == statusFilter } }
        let words = query.lowercased().split(separator: " ").map(String.init)
        if !words.isEmpty {
            list = list.filter { s in
                let hay = "\(s.name) \(s.url.host ?? "") \(s.geohash6) \(s.terms.attribution)".lowercased()
                return words.allSatisfy(hay.contains)
            }
        }
        func key(_ s: PublicFeedSource) -> String {
            switch sortKey {
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
                    Text("★ Favorites (\(favorites.ids.count))").tag(Tab.favorites)
                }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 340)
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
            if tab == .all { controls }
            if tab == .favorites { favoritesGrid } else { listAndPreview }
            if tab == .all {
                Text("\(rows.count) of \(totalCount) cameras. robots.txt is honoured; one request per camera per refresh interval.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding()
        .onAppear(perform: reload)
        .onChange(of: hub.feedRunner.status) { _, _ in reload() }
        .sheet(item: Binding(get: { reviewing.map(HostBox.init) }, set: { reviewing = $0?.host })) { box in
            TermsReviewSheet(hub: hub, host: box.host, sample: catalogue?.sources.first { $0.url.host == box.host.host }) {
                reviewing = nil; reload()
            }
        }
    }

    // MARK: Pieces

    private var termsBanner: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Cameras are not polled until you review and confirm each image host's terms.", systemImage: "hand.raised")
                .font(.headline)
            ForEach(needReview, id: \.host) { h in
                HStack {
                    Text(h.host).monospaced()
                    Text("\(h.totalCount - h.confirmedCount) of \(h.totalCount) cameras waiting").foregroundStyle(.secondary)
                    Spacer()
                    Button("Review terms…") { reviewing = h }.buttonStyle(.borderedProminent)
                }
            }
        }
        .padding(12).background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 10))
    }

    private var controls: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search name, host or area", text: $query).textFieldStyle(.plain)
                if !query.isEmpty { Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).foregroundStyle(.secondary) }
            }
            .padding(6).background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 8)).frame(maxWidth: 300)
            Picker("Source", selection: $hostFilter) {
                Text("All sources").tag("")
                ForEach(hosts, id: \.host) { Text("\($0.host) (\($0.totalCount))").tag($0.host) }
            }.frame(maxWidth: 260)
            Picker("Status", selection: $statusFilter) {
                Text("Any status").tag(FeedRunner.StatusKind?.none)
                ForEach(FeedRunner.StatusKind.allCases) { Text($0.rawValue).tag(FeedRunner.StatusKind?.some($0)) }
            }.frame(maxWidth: 200)
            Spacer()
            Picker("Sort", selection: $sortKey) { ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) } }.frame(maxWidth: 150)
            Button { ascending.toggle() } label: { Image(systemName: ascending ? "arrow.up" : "arrow.down") }
                .help(ascending ? "Ascending" : "Descending")
            Toggle("★ first", isOn: $favoritesFirst).toggleStyle(.checkbox)
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
                TableColumn("Camera") { Text($0.name) }
                TableColumn("Host") { Text($0.url.host ?? "") }
                TableColumn("Location") { Text($0.geohash6.isEmpty ? "unknown" : $0.geohash6).monospaced() }.width(70)
                TableColumn("Status") { s in
                    let state = hub.feedRunner.state(of: s)
                    Label(state.text, systemImage: state.icon).foregroundStyle(state.color)
                }
            }
            .frame(minWidth: 460)
            CameraPreviewPanel(hub: hub, favorites: favorites,
                               source: selected.first.flatMap { id in catalogue?.sources.first { $0.id == id } })
                .frame(minWidth: 300, idealWidth: 380)
        }
    }

    private var favoritesGrid: some View {
        let favs = (catalogue?.sources ?? []).filter { favorites.contains($0.id) }.sorted { $0.name < $1.name }
        return Group {
            if favs.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "star").font(.largeTitle).foregroundStyle(.secondary)
                    Text("No favorites yet").font(.headline)
                    Text("Click the ☆ next to a camera in All feeds to pin it here with a live thumbnail.").foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12)], spacing: 12) {
                        ForEach(favs) { FavoriteTile(hub: hub, favorites: favorites, source: $0) }
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
    @State private var image: NSImage?
    @State private var message = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack {
                Rectangle().fill(.black.opacity(0.85))
                if let image { Image(nsImage: image).resizable().scaledToFit() }
                else { Text(message.isEmpty ? "Loading…" : message).font(.caption).foregroundStyle(.secondary).padding(8) }
            }.aspectRatio(16 / 9, contentMode: .fit).clipShape(RoundedRectangle(cornerRadius: 8))
            HStack {
                Text(source.name).font(.callout.bold()).lineLimit(1)
                Spacer()
                Button { favorites.toggle(source.id) } label: { Image(systemName: "star.fill").foregroundStyle(.yellow) }
                    .buttonStyle(.plain).help("Remove from favorites")
            }
            Text(source.url.host ?? "").font(.caption2).foregroundStyle(.secondary).monospaced()
        }
        .task(id: source.id) {
            while !Task.isCancelled {
                do {
                    let data = try await hub.feedRunner.fetchPreview(of: source)
                    if let img = NSImage(data: data) { image = img; message = "" }
                } catch { image = nil; message = error.localizedDescription }
                try? await Task.sleep(for: .seconds(max(source.refreshInterval, 30)))
            }
        }
    }
}

/// Shows the selected camera's current frame, refreshed no faster than the source's own interval.
struct CameraPreviewPanel: View {
    @ObservedObject var hub: HubController
    @ObservedObject var favorites: FeedFavorites
    let source: PublicFeedSource?
    @State private var image: NSImage?
    @State private var fetchedAt: Date?
    @State private var message = ""

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
                }
                Text(source.url.host ?? "").font(.caption).foregroundStyle(.secondary).monospaced()
                ZStack {
                    Rectangle().fill(.black.opacity(0.85))
                    if let image { Image(nsImage: image).resizable().scaledToFit() }
                    else { Text(message.isEmpty ? "Loading…" : message).foregroundStyle(.secondary).padding() }
                }
                .frame(maxWidth: .infinity, minHeight: 200)
                HStack {
                    if let fetchedAt { Text("Updated \(fetchedAt, format: .dateTime.hour().minute().second())").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Refresh now") { Task { await load(source) } }
                }
                if !source.mayBeAnalysed {
                    Text("Confirm this host's terms (Review terms…) to view and poll its cameras.").font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Select a camera to see its current frame.").foregroundStyle(.secondary)
                Spacer()
            }
        }
        .padding()
        .task(id: source?.id) {
            image = nil; fetchedAt = nil; message = ""
            guard let source else { return }
            while !Task.isCancelled {
                await load(source)
                try? await Task.sleep(for: .seconds(max(source.refreshInterval, 10)))
            }
        }
    }

    private func load(_ source: PublicFeedSource) async {
        do {
            let data = try await hub.feedRunner.fetchPreview(of: source)
            if let img = NSImage(data: data) { image = img; fetchedAt = Date(); message = "" }
        } catch { message = error.localizedDescription; image = nil }
    }
}
