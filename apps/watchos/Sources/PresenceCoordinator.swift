import Foundation
import PlateSync

/// Reports only that the companion is currently in use. The watch has no
/// camera or feed processor, so it never contributes to processor/feed counts.
@MainActor
final class WatchPresenceCoordinator {
    static let shared = WatchPresenceCoordinator()
    private let sessionID: String
    private var task: Task<Void, Never>?

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "presenceSessionID") {
            sessionID = saved
        } else {
            let created = UUID().uuidString.lowercased()
            UserDefaults.standard.set(created, forKey: "presenceSessionID")
            sessionID = created
        }
    }

    func start() {
        guard task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.heartbeat()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let id = sessionID
        Task { try? await PresenceClient(baseURL: SyncBackends.mirrorURL()).release(sessionID: id) }
    }

    private func heartbeat() async {
        let payload = PresenceHeartbeat(sessionID: sessionID, platform: "watchOS",
                                        feedIDs: [], activeProcessing: false)
        try? await PresenceClient(baseURL: SyncBackends.mirrorURL()).heartbeat(payload)
    }
}
