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
        let markings = SceneTextHeuristics.parse(vehicle.sceneText)
        let confidence = gate.fleetConfidence(
            vehicleClassifierFleet: vehicle.vehicleClass.isFleet ? vehicle.classConfidence : 0,
            markings: markings,
            knownUnitMatch: knownUnitMatch,
            exemptPlateDesign: vehicle.plates.contains { $0.best?.exemptDesignHint == true },
            officialPlate: vehicle.plates.contains { $0.best?.isOfficialPlate == true })
        return (confidence, markings)
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
