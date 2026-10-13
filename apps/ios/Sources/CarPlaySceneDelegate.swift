import CarPlay
import Foundation

/// Shared, thread-safe capture status that both the SwiftUI capture loop and
/// the CarPlay scene read. CarPlay is display-only (passive mode): it never
/// touches the camera — capture continues on the phone as normal.
final class PassiveCaptureStatus: @unchecked Sendable {
    static let shared = PassiveCaptureStatus()

    private let lock = NSLock()
    private var _statusText = "idle"
    private var _fleetHit = false
    private var _modelStatus = "baseline vision"
    private var onChange: (() -> Void)?

    var statusText: String {
        get { lock.lock(); defer { lock.unlock() }; return _statusText }
    }
    var fleetHit: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _fleetHit }
    }
    var modelStatus: String {
        get { lock.lock(); defer { lock.unlock() }; return _modelStatus }
    }

    func set(statusText: String, fleetHit: Bool, modelStatus: String) {
        lock.lock()
        _statusText = statusText
        _fleetHit = fleetHit
        _modelStatus = modelStatus
        let handler = onChange
        lock.unlock()
        handler?()
    }

    /// UI hook installed by the CarPlay scene to refresh its template.
    func observe(_ handler: (() -> Void)?) {
        lock.lock()
        onChange = handler
        lock.unlock()
    }
}

/// CarPlay passive-capture scene (M4). Shows live capture status and
/// privacy posture while driving; the phone keeps scanning as usual.
/// Requires the CarPlay entitlement on provisioned builds — unsigned builds
/// compile fine and simply never activate the scene.
@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {

    private var interfaceController: CPInterfaceController?
    private var listTemplate: CPListTemplate?

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didConnect interfaceController: CPInterfaceController) {
        self.interfaceController = interfaceController

        let statusItem = CPListItem(text: "Passive capture", detailText: statusDetail())
        let privacyItem = CPListItem(text: "On-device only",
                                     detailText: "Frames analyzed on the phone. Only fleet-confirmed records sync. No raw footage leaves the device.")
        privacyItem.setImage(nil)
        let watchItem = CPListItem(text: "Watchlist",
                                   detailText: "Alerts and haptics continue on your paired watch.")
        let sections: [CPListSection] = [
            CPListSection(items: [statusItem]),
            CPListSection(items: [privacyItem, watchItem]),
        ]
        let template = CPListTemplate(title: "PlateWatch", sections: sections)
        template.tabTitle = "PlateWatch"
        template.tabImage = UIImage(systemName: "camera.viewfinder")
        listTemplate = template
        interfaceController.setRootTemplate(template, animated: false) { _, _ in }

        // Refresh the status row as the capture loop updates it.
        PassiveCaptureStatus.shared.observe { [weak self] in
            self?.refresh()
        }
    }

    func templateApplicationScene(_ templateApplicationScene: CPTemplateApplicationScene,
                                  didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        PassiveCaptureStatus.shared.observe(nil)
        self.interfaceController = nil
        listTemplate = nil
    }

    private func statusDetail() -> String {
        let s = PassiveCaptureStatus.shared
        let hit = s.fleetHit ? " · fleet vehicle detected" : ""
        return "\(s.statusText)\(hit) · \(s.modelStatus)"
    }

    private func refresh() {
        guard let item = listTemplate?.sections.first?.items.first as? CPListItem else { return }
        // Setting the detail text is enough — CarPlay observes item changes
        // and refreshes the current template itself.
        item.setDetailText(statusDetail())
    }
}
