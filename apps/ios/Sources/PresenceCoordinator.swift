import Foundation
import PlateSync

/// Optional, ephemeral presence. Disabled by default. Signed builds publish an anonymous, expiring lease to the CloudKit
/// public database (`PresenceLease`, docs/PRESENCE-DESIGN.md); development builds use the reference server.
/// While enabled and the app is active it also *reads* the aggregate and relays it to the paired watch, which has no
/// route to the backend of its own. Nothing here is related to sighting records.
@MainActor
final class PresenceCoordinator {
    static let shared = PresenceCoordinator()

    private let sessionID: String
    private var task: Task<Void, Never>?
    /// True only while the camera is actually scanning; otherwise this install is "present" but not a processor.
    private var processing = false
    private(set) var status = "Off"

    private init() {
        if let saved = UserDefaults.standard.string(forKey: "presenceSessionID") {
            sessionID = saved
        } else {
            let created = UUID().uuidString.lowercased()
            UserDefaults.standard.set(created, forKey: "presenceSessionID")
            sessionID = created
        }
    }

    private var enabled: Bool { UserDefaults.standard.bool(forKey: "presenceEnabled") }

    /// Called when the app becomes active, when capture starts, and when the setting is switched on.
    func start(processing: Bool = false) {
        if processing { self.processing = true }
        guard enabled, task == nil else { return }
        status = "Connecting…"
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.sendHeartbeat()
                try? await Task.sleep(for: .seconds(45))
            }
        }
    }

    /// Capture stopped: stay present (so the watch keeps its counts) but no longer count as a processor.
    func captureStopped() {
        processing = false
        if enabled { Task { await sendHeartbeat() } }
    }

    /// App backgrounded or the setting was turned off: withdraw the lease.
    func stop() {
        task?.cancel()
        task = nil
        processing = false
        status = "Off"
        let id = sessionID
        Task { _ = try? await PresenceServices.makeDefault().release(sessionID: id) }
    }

    private func sendHeartbeat() async {
        guard enabled else { return }
        let payload = PresenceHeartbeat(sessionID: sessionID, platform: "iOS", feedIDs: [], activeProcessing: processing)
        do {
            let aggregate = try await PresenceServices.makeDefault().heartbeat(payload)
            status = "Live"
            WatchlistConnectivity.shared.send(presence: aggregate)
        } catch {
            status = (error as? PresenceError)?.statusText ?? "Offline"
        }
    }
}
