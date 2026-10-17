import Foundation
import PlateSync

/// Optional, ephemeral presence for active on-device capture. It is disabled
/// by default and has no relationship to CloudKit sighting records.
@MainActor
final class PresenceCoordinator {
    static let shared = PresenceCoordinator()

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
        guard UserDefaults.standard.bool(forKey: "presenceEnabled"), task == nil else { return }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendHeartbeat()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        let id = sessionID
        Task {
            try? await PresenceClient(baseURL: SyncBackends.mirrorURL()).release(sessionID: id)
        }
    }

    private func sendHeartbeat() async {
        guard UserDefaults.standard.bool(forKey: "presenceEnabled") else { return }
        let payload = PresenceHeartbeat(sessionID: sessionID, platform: "iOS",
                                        feedIDs: [], activeProcessing: true)
        try? await PresenceClient(baseURL: SyncBackends.mirrorURL()).heartbeat(payload)
    }
}
