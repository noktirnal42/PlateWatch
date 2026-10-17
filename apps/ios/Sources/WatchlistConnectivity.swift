import Foundation
import PlateKit
import WatchConnectivity

/// Sends the local, operator-entered fleet watchlist to the paired watch.
/// Only normalized plate strings cross WatchConnectivity; no sightings,
/// images, locations, credentials or model output are mirrored.
final class WatchlistConnectivity: NSObject, WCSessionDelegate, @unchecked Sendable {
    static let shared = WatchlistConnectivity()

    private override init() { super.init() }

    func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
    }

    func send(plates: [String]) {
        guard WCSession.isSupported() else { return }
        let normalized = Array(Set(plates.map(PlateKit.Plate.normalize))).sorted()
        try? WCSession.default.updateApplicationContext(["watchlistPlates": normalized])
    }

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: Error?) {}

#if os(iOS)
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { session.activate() }
#endif
}
