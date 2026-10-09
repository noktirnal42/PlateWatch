import Foundation

/// The privacy enforcement point between on-device detection and any
/// persistence/sync. This gate implements LEGAL-ETHICS Rule 1; it is
/// duplicated server-side. Detections that do not pass never leave the
/// device.
public struct RedactionGate: Sendable {

    public struct Config: Sendable {
        /// Minimum combined fleet confidence to persist + sync a sighting.
        public var persistThreshold: Double
        /// Below this, even on-device retention is dropped immediately after
        /// analysis (rolling buffer scope only).
        public var keepOnDeviceThreshold: Double

        public static let standard = Config(persistThreshold: 0.55, keepOnDeviceThreshold: 0.15)
        /// Strict jurisdictions (EU/UK, see LEGAL-ETHICS): fleet-tagged only.
        public static let strict = Config(persistThreshold: 0.8, keepOnDeviceThreshold: 0.5)

        public init(persistThreshold: Double, keepOnDeviceThreshold: Double) {
            self.persistThreshold = persistThreshold
            self.keepOnDeviceThreshold = keepOnDeviceThreshold
        }
    }

    public enum Verdict: Sendable, Equatable {
        case discard
        case keepLocalOnly
        case persistAndSync
    }

    public let config: Config
    public init(config: Config = .standard) { self.config = config }

    /// Weighted evidence model. Inputs are cheap signals from the pipeline:
    ///  - vehicleClassifierFleet: P(vehicle is a fleet class)
    ///  - hasFleetMarkings: door/hood text parser found agency text, "POLICE",
    ///    "FIRE", unit format etc.
    ///  - knownUnitMatch: unit number parsed here matches a cached public
    ///    fleet roster entry
    ///  - exemptPlateDesign: government/exempt plate design hint
    public func fleetConfidence(vehicleClassifierFleet: Double,
                                hasFleetMarkings: Bool,
                                knownUnitMatch: Bool,
                                exemptPlateDesign: Bool) -> Double {
        var score = 0.45 * min(1, max(0, vehicleClassifierFleet))
        if hasFleetMarkings { score += 0.30 }
        if knownUnitMatch { score += 0.20 }
        if exemptPlateDesign { score += 0.15 }
        return min(1, score)
    }

    public func verdict(fleetConfidence: Double) -> Verdict {
        if fleetConfidence >= config.persistThreshold { return .persistAndSync }
        if fleetConfidence >= config.keepOnDeviceThreshold { return .keepLocalOnly }
        return .discard
    }

    /// Decide + produce the sanitized copy in one call: background plates that
    /// belong to non-fleet observations are dropped from the sync payload.
    public func gate(_ frame: DetectionFrame, confidences: [UUID: Double]) -> (verdicts: [UUID: Verdict], sanitized: DetectionFrame) {
        var verdicts: [UUID: Verdict] = [:]
        var kept: [VehicleObservation] = []
        for vehicle in frame.vehicles {
            let c = confidences[vehicle.id] ?? 0
            let v = verdict(fleetConfidence: c)
            verdicts[vehicle.id] = v
            if v == .persistAndSync { kept.append(vehicle) }
        }
        var sanitized = frame
        sanitized.vehicles = kept
        return (verdicts, sanitized)
    }
}
