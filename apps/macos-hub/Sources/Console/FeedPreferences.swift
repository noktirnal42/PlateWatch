import Foundation
import SwiftUI

/// Local camera preferences. Blocking preserves the source catalogue and star so it can be undone.
@MainActor
final class FeedFavorites: ObservableObject {
    @Published private(set) var ids: Set<UUID>
    @Published private(set) var blockedIDs: Set<UUID>
    /// Cameras chosen for background analysis (the eye toggle). Nothing is
    /// polled or decoded unless it is watched (or open in Live).
    @Published private(set) var watchedIDs: Set<UUID>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set((defaults.stringArray(forKey: "hubFavoriteFeeds") ?? []).compactMap(UUID.init(uuidString:)))
        blockedIDs = Set((defaults.stringArray(forKey: "hubBlockedFeeds") ?? []).compactMap(UUID.init(uuidString:)))
        watchedIDs = Set((defaults.stringArray(forKey: "hubWatchedFeeds") ?? []).compactMap(UUID.init(uuidString:)))
    }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
    func isBlocked(_ id: UUID) -> Bool { blockedIDs.contains(id) }
    func isWatched(_ id: UUID) -> Bool { watchedIDs.contains(id) }
    func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        defaults.set(ids.map(\.uuidString).sorted(), forKey: "hubFavoriteFeeds")
    }
    func toggleBlocked(_ id: UUID) {
        if blockedIDs.contains(id) { blockedIDs.remove(id) } else { blockedIDs.insert(id) }
        defaults.set(blockedIDs.map(\.uuidString).sorted(), forKey: "hubBlockedFeeds")
    }
    func setWatched(_ id: UUID, watched: Bool) {
        if watched { watchedIDs.insert(id) } else { watchedIDs.remove(id) }
        defaults.set(watchedIDs.map(\.uuidString).sorted(), forKey: "hubWatchedFeeds")
    }
    func toggleWatched(_ id: UUID) -> Bool {
        setWatched(id, watched: !watchedIDs.contains(id))
        return watchedIDs.contains(id)
    }
}

/// Persisted feed-browser UI state (tab, search, filters, sort, selection).
@MainActor
final class FeedBrowserState: ObservableObject {
    enum Tab: String, CaseIterable, Identifiable { case all = "All feeds", favorites = "Favorites", blocked = "Blocked"; var id: String { rawValue } }
    enum SortKey: String, CaseIterable, Identifiable { case state = "State", name = "Name", host = "Host", location = "Location", status = "Status"; var id: String { rawValue } }

    @Published var tab: Tab = .all
    @Published var query: String = ""
    @Published var hostFilter: String = ""
    @Published var statusFilter: FeedRunner.StatusKind?
    @Published var sortKey: SortKey = .state
    @Published var ascending: Bool = true
    @Published var favoritesFirst: Bool = false
    @Published var selected: Set<UUID> = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let tabRaw = defaults.string(forKey: "hubFeedBrowserTab"), let t = Tab(rawValue: tabRaw) { tab = t }
        query = defaults.string(forKey: "hubFeedBrowserQuery") ?? ""
        hostFilter = defaults.string(forKey: "hubFeedBrowserHostFilter") ?? ""
        if let statusRaw = defaults.string(forKey: "hubFeedBrowserStatusFilter"), let s = FeedRunner.StatusKind(rawValue: statusRaw) { statusFilter = s }
        if let sortRaw = defaults.string(forKey: "hubFeedBrowserSortKey"), let s = SortKey(rawValue: sortRaw) { sortKey = s }
        ascending = (defaults.object(forKey: "hubFeedBrowserAscending") as? Bool) ?? true
        favoritesFirst = defaults.bool(forKey: "hubFeedBrowserFavoritesFirst")
        if let selectedStrings = defaults.stringArray(forKey: "hubFeedBrowserSelected") {
            selected = Set(selectedStrings.compactMap(UUID.init(uuidString:)))
        }
    }

    func save() {
        defaults.set(tab.rawValue, forKey: "hubFeedBrowserTab")
        defaults.set(query, forKey: "hubFeedBrowserQuery")
        defaults.set(hostFilter, forKey: "hubFeedBrowserHostFilter")
        defaults.set(statusFilter?.rawValue, forKey: "hubFeedBrowserStatusFilter")
        defaults.set(sortKey.rawValue, forKey: "hubFeedBrowserSortKey")
        defaults.set(ascending, forKey: "hubFeedBrowserAscending")
        defaults.set(favoritesFirst, forKey: "hubFeedBrowserFavoritesFirst")
        defaults.set(selected.map(\.uuidString).sorted(), forKey: "hubFeedBrowserSelected")
    }
}
