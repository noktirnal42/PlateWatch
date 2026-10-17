import PlateKit

enum VehicleOverlayLabel {
    static func text(for vehicle: VehicleObservation, fleetConfidence: Double) -> String {
        let body = vehicle.attributes?.bodyType.flatMap { value -> String? in
            switch value.lowercased().replacingOccurrences(of: "_", with: " ") {
            case "car", "automobile", "sedan", "coupe", "hatchback": return "Car"
            case "truck", "lorry": return "Truck"
            case "bus", "coach": return "Bus"
            case "motorcycle", "motorbike": return "Motorcycle"
            case "suv", "sport utility vehicle", "sport utility": return "SUV"
            case "van", "minivan": return "Van"
            case "pickup", "pickup truck": return "Pickup"
            default: return nil
            }
        }
        let color = vehicle.attributes?.color.flatMap { value -> String? in
            let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cleaned.isEmpty else { return nil }
            return cleaned.prefix(1).uppercased() + cleaned.dropFirst().lowercased()
        }
        let vehicleLabel = [color, body].compactMap { $0 }.joined(separator: " ")
        guard vehicle.vehicleClass.isFleet else {
            guard vehicle.classConfidence.isFinite, vehicle.classConfidence > 0 else {
                return vehicleLabel.isEmpty ? "Vehicle" : vehicleLabel
            }
            let score = Int(min(1, max(0, vehicle.classConfidence)) * 100)
            return "\(vehicleLabel.isEmpty ? "Vehicle" : vehicleLabel) · class \(score)%"
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
        let fleetLabel = [color, body ?? "Vehicle"].compactMap { $0 }.joined(separator: " ")
        return [fleetLabel, fleet, "fleet \(score)%"].joined(separator: " · ")
    }
}
