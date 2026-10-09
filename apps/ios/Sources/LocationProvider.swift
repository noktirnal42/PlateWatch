import CoreLocation
import Foundation
import PlateKit

/// Coarse-grained location source for geo bucketing. Uses the system's last
/// known location whenever possible — we bucket to geohash-6 (~1 km) before
/// anything leaves the device, so GPS precision doesn't need to run hot.
@MainActor
final class LocationProvider: NSObject, CLLocationManagerDelegate {
    static let shared = LocationProvider()

    private let manager = CLLocationManager()
    private var lastLocation: CLLocation?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters // buckets don't need better
    }

    /// Call once at app start; location is requested lazily when capture runs.
    func authorizeIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    /// Current geohash-6 bucket, from the freshest known fix we can get
    /// without warming GPS (last known → requestLocation fallback).
    func currentBucket() -> GeoBucket? {
        if let last = lastLocation ?? manager.location {
            return GeoBucket(latitude: last.coordinate.latitude,
                             longitude: last.coordinate.longitude)
        }
        if manager.authorizationStatus == .authorizedWhenInUse
            || manager.authorizationStatus == .authorizedAlways {
            manager.requestLocation() // async; next read has a fix
        }
        return nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager,
                                     didUpdateLocations locations: [CLLocation]) {
        let latest = locations.last
        Task { @MainActor in self.lastLocation = latest }
    }
}
