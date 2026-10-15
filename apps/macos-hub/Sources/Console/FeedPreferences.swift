import Foundation
import SwiftUI

/// Local camera preferences. Blocking preserves the source catalogue and star so it can be undone.
@MainActor
final class FeedFavorites: ObservableObject {
    @Published private(set) var ids: Set<UUID>
    @Published private(set) var blockedIDs: Set<UUID>
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        ids = Set((defaults.stringArray(forKey: "hubFavoriteFeeds") ?? []).compactMap(UUID.init(uuidString:)))
        blockedIDs = Set((defaults.stringArray(forKey: "hubBlockedFeeds") ?? []).compactMap(UUID.init(uuidString:)))
    }
    func contains(_ id: UUID) -> Bool { ids.contains(id) }
    func isBlocked(_ id: UUID) -> Bool { blockedIDs.contains(id) }
    func toggle(_ id: UUID) {
        if ids.contains(id) { ids.remove(id) } else { ids.insert(id) }
        defaults.set(ids.map(\.uuidString).sorted(), forKey: "hubFavoriteFeeds")
    }
    func toggleBlocked(_ id: UUID) {
        if blockedIDs.contains(id) { blockedIDs.remove(id) } else { blockedIDs.insert(id) }
        defaults.set(blockedIDs.map(\.uuidString).sorted(), forKey: "hubBlockedFeeds")
    }
}
