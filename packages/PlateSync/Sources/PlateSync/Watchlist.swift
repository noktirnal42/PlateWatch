import Foundation
import PlateKit
import SwiftData

/// User-scoped watchlist item (persistent). Never synced, never published —
/// evaluates matches on-device against detection frames and (via push)
/// against fleet-confirmed sightings from the shared database.
@Model
public final class WatchlistItem {
    @Attribute(.unique) public var id: UUID
    public var plateText: String?
    public var featurePrintAnchor: String?
    public var label: String?                  // user's own note ("city yard truck")
    public var notifyEnabled: Bool
    public var createdAt: Date

    public init(id: UUID = UUID(), plateText: String? = nil,
                featurePrintAnchor: String? = nil, label: String? = nil,
                notifyEnabled: Bool = true, createdAt: Date = Date()) {
        self.id = id
        self.plateText = plateText.map(Plate.normalize)
        self.featurePrintAnchor = featurePrintAnchor
        self.label = label
        self.notifyEnabled = notifyEnabled
        self.createdAt = createdAt
    }
}

/// Local match evaluation. Called per fleet-approved frame by the capture
/// pipeline; the UI layer decides how to alert (banner/haptic via push).
public enum WatchlistEvaluator {

    public struct Hit: Sendable {
        /// Stable identifiers back to the model (models aren't Sendable).
        public var itemID: UUID
        public var itemLabel: String?
        public var matchedPlate: String?
        public var matchedAnchor: String?
    }

    /// Evaluate a detection frame against the user's items.
    public static func evaluate(_ frame: DetectionFrame,
                                items: [WatchlistItem]) -> [Hit] {
        guard !items.isEmpty else { return [] }
        var hits: [Hit] = []
        for item in items where item.notifyEnabled {
            for vehicle in frame.vehicles {
                if let want = item.plateText,
                   let got = vehicle.plates.compactMap(\.best).first(where: {
                       Plate.normalize($0.rawText) == want
                   }) {
                    hits.append(Hit(itemID: item.id, itemLabel: item.label,
                                    matchedPlate: got.text, matchedAnchor: nil))
                    break
                }
                if let wantAnchor = item.featurePrintAnchor,
                   vehicle.featurePrintAnchorLookahead == wantAnchor {
                    hits.append(Hit(itemID: item.id, itemLabel: item.label,
                                    matchedPlate: nil, matchedAnchor: wantAnchor))
                }
            }
        }
        return hits
    }
}
