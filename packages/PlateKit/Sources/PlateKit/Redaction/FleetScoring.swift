import Foundation

/// Single entry point for gate scoring. Every caller (iOS capture, watchOS,
/// macOS Hub, eval harness, future feeds) must score through this helper —
/// per-app copies drifted once already and broke the Hub build when
/// `fleetConfidence` gained parameters.
public enum FleetScoring {
    /// Parse the vehicle's scene text and score it against the gate.
    /// Returns the confidence and the markings it was derived from so callers
    /// can display both without re-parsing.
    public static func vehicleGateScore(gate: RedactionGate,
                                        vehicle: VehicleObservation,
                                        knownUnitMatch: Bool = false) -> (confidence: Double, markings: FleetMarkings) {
        vehicleGateScore(gate: gate, vehicle: vehicle,
                         markings: SceneTextHeuristics.parse(vehicle.sceneText), knownUnitMatch: knownUnitMatch)
    }

    /// Same scoring with markings the caller already parsed (e.g. the on-device LLM parser on iOS
    /// 26+). The scoring itself stays in this one place.
    public static func vehicleGateScore(gate: RedactionGate,
                                        vehicle: VehicleObservation,
                                        markings: FleetMarkings,
                                        knownUnitMatch: Bool = false) -> (confidence: Double, markings: FleetMarkings) {
        let confidence = gate.fleetConfidence(
            vehicleClassifierFleet: vehicle.vehicleClass.isFleet ? vehicle.classConfidence : 0,
            markings: markings,
            knownUnitMatch: knownUnitMatch,
            exemptPlateDesign: vehicle.plates.contains { $0.best?.exemptDesignHint == true },
            officialPlate: vehicle.plates.contains { $0.best?.isOfficialPlate == true })
        return (confidence, markings)
    }

    /// May this sighting carry the plate registration? The same rule the server and CloudKit
    /// backends apply (fleet-confirmed: ≥ 0.8 with markings or a government plate design).
    public static func mayCarryPlate(confidence: Double, markings: FleetMarkings, vehicle: VehicleObservation) -> Bool {
        let hasMarkings = markings.agencyText != nil || markings.unitNumber != nil
        let governmentDesign = vehicle.plates.contains { $0.best?.exemptDesignHint == true }
        return confidence >= 0.8 && (hasMarkings || governmentDesign)
    }

    /// Convenience: best vehicle in a frame (highest score) with its verdict.
    public static func frameGateOutcome(gate: RedactionGate,
                                        frame: DetectionFrame) -> (bestConfidence: Double,
                                                                   bestMarkings: FleetMarkings,
                                                                   anyApproved: Bool,
                                                                   anyReviewable: Bool) {
        var best = 0.0
        var bestMarkings = FleetMarkings()
        var approved = false
        var reviewable = false
        for vehicle in frame.vehicles {
            let (confidence, markings) = vehicleGateScore(gate: gate, vehicle: vehicle)
            if confidence >= best { best = confidence; bestMarkings = markings }
            switch gate.verdict(fleetConfidence: confidence) {
            case .persistAndSync: approved = true
            case .keepLocalOnly:
                if markings.hasFleetKeyword || (vehicle.vehicleClass.isFleet && vehicle.classConfidence > 0) {
                    reviewable = true
                }
            case .discard: break
            }
        }
        return (best, bestMarkings, approved, reviewable)
    }
}
