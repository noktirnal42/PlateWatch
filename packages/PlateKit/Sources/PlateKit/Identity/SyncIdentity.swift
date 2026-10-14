import Foundation

extension IdentityResolver {

    /// The identity that may leave the device for one sighting — shared by every ingest path (iPhone capture,
    /// Hub folder/HTTP, feed pollers) so they apply the same rules:
    ///  - the registration is stripped unless the sighting may carry a plate (`FleetScoring.mayCarryPlate`);
    ///  - `forceReview` (e.g. a low-resolution feed frame, where lettering is barely readable) marks the agency as
    ///    needing review and also strips the registration, so a marginal read is never asserted as fact;
    ///  - `location` is the frame source's position (the camera's catalogued geohash centre for a feed), never the
    ///    device running the analysis.
    /// Returns nil when nothing identifying was found.
    public func syncIdentity(vehicle: VehicleObservation, markings: FleetMarkings, confidence: Double,
                             location: LocationHint?, forceReview: Bool = false) -> VehicleIdentity? {
        var identity = resolve(sceneText: vehicle.sceneText, plates: vehicle.plates,
                               vehicleClass: vehicle.vehicleClass, markings: markings,
                               location: location, enhancedText: vehicle.enhancedText)
        guard !identity.isEmpty else { return nil }
        if forceReview, var agency = identity.agency {
            agency.needsReview = true
            identity.agency = agency
        }
        let mayCarry = !forceReview
            && FleetScoring.mayCarryPlate(confidence: confidence, markings: markings, vehicle: vehicle)
        return mayCarry ? identity : identity.redactingRegistration()
    }
}

public extension IdentityResolver.LocationHint {
    /// The centre of a geohash-6 cell (a fixed camera's catalogued position), or nil if it does not decode.
    init?(geohash6: String) {
        guard let c = Geohash.decodeCenter(geohash6) else { return nil }
        self.init(latitude: c.latitude, longitude: c.longitude)
    }
}
