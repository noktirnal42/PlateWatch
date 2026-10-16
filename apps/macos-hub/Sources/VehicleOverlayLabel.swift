import PlateKit

enum VehicleOverlayLabel {
    static func text(for vehicle: VehicleObservation, fleetConfidence: Double) -> String {
        let body = vehicle.attributes?.bodyType.flatMap { value -> String? in
            switch value.lowercased() {
            case "car": return "Car"
            case "truck": return "Truck"
            case "bus": return "Bus"
            case "motorcycle": return "Motorcycle"
            default: return nil
            }
        }
        guard vehicle.vehicleClass.isFleet else {
            guard let body else { return "Vehicle" }
            guard vehicle.classConfidence.isFinite, vehicle.classConfidence > 0 else { return body }
            let score = Int(min(1, max(0, vehicle.classConfidence)) * 100)
            return "\(body) · class (score)%"
        }
        let fleet: String
        switch vehicle.vehicleClass {
        case .patrol: fleet = "Patrol"
        case .fireEngine: fleet = "Fire engine"
        case .ambulance: fleet = "Ambulance"
        case .publicWorks: fleet = "Public works"
        case .transit: fleet = "Transit"
        case .schoolBus: fleet = "School bus"
        case .federal: fleet = "Federal"
        case .military: fleet = "Military"
        case .parkRanger: fleet = "Park ranger"
        case .highway: fleet = "Highway"
        default: fleet = "Fleet"
        }
        let score = fleetConfidence.isFinite ? Int(min(1, max(0, fleetConfidence)) * 100) : 0
        return [body, fleet, "fleet \(score)%"].compactMap { $0 }.joined(separator: " · ")
    }
}
