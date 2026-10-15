import CoreLocation
import PlateKit
import SwiftUI

/// One-shot position from macOS Location Services, only when the person asks for it.
@MainActor
final class LocationFinder: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var status = ""
    @Published private(set) var busy = false
    var onFix: ((Double, Double) -> Void)?
    private let manager = CLLocationManager()

    override init() { super.init(); manager.delegate = self; manager.desiredAccuracy = kCLLocationAccuracyKilometer }

    private var timeout: Task<Void, Never>?

    func request() {
        guard CLLocationManager.locationServicesEnabled() else { status = "Location Services are off (System Settings › Privacy & Security)."; return }
        busy = true; status = "Finding your location…"
        timeout?.cancel()
        // Never hang silently: if no fix arrives (no permission prompt on an unsigned build, or no Wi-Fi/GPS data), say so.
        timeout = Task { @MainActor in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, busy else { return }
            let auth: String
            switch manager.authorizationStatus {
            case .notDetermined: auth = "permission not yet granted"
            case .denied: auth = "permission denied"
            case .restricted: auth = "restricted"
            default: auth = "permission granted but no position available"
            }
            finish("No location fix after 15 s (\(auth)). Check System Settings › Privacy & Security › Location Services, or enter coordinates or a Plus Code below.")
        }
        switch manager.authorizationStatus {
        case .denied, .restricted:
            finish("Location access is denied for PlateWatchHub (System Settings › Privacy & Security › Location Services).")
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: manager.startUpdatingLocation()
        }
    }

    private func finish(_ message: String) {
        manager.stopUpdatingLocation()
        timeout?.cancel(); timeout = nil
        busy = false; status = message
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let auth = manager.authorizationStatus
        Task { @MainActor in
            switch auth {
            case .authorizedAlways, .authorized: if busy { self.manager.startUpdatingLocation() }
            case .denied, .restricted: if busy { finish("Location access was denied.") }
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last else { return }
        Task { @MainActor in
            guard busy else { return }
            finish("Using your current location.")
            onFix?(l.coordinate.latitude, l.coordinate.longitude)
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        // `kCLErrorLocationUnknown` is transient ("no fix yet"): keep waiting; the timeout reports a persistent failure.
        if (error as? CLError)?.code == .locationUnknown { return }
        Task { @MainActor in finish("Could not get a location: \(error.localizedDescription)") }
    }
}

/// Home location for this Hub. Only a ~1 km geohash is kept (never the exact point).
struct HomeLocationSection: View {
    @ObservedObject var hub: HubController
    @Binding var geohash: String
    @StateObject private var finder = LocationFinder()
    @State private var coordinates = ""
    @State private var plusCode = ""
    @State private var message = ""

    var body: some View {
        Section("Home location (decides whether plate reading may run)") {
            HStack {
                Button { finder.request() } label: { Label("Use my location", systemImage: "location") }
                    .disabled(finder.busy)
                Text(finder.status).font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                TextField("Latitude, longitude  (e.g. 44.9778, -93.2650)", text: $coordinates).onSubmit(applyCoordinates)
                Button("Set") { applyCoordinates() }.disabled(coordinates.isEmpty)
            }
            HStack {
                TextField("Plus Code  (e.g. 86P8WQ3M+8Q, or 8WQ3M+8Q near here)", text: $plusCode).onSubmit(applyPlusCode)
                Button("Set") { applyPlusCode() }.disabled(plusCode.isEmpty)
            }
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.red) }
            LabeledContent("Saved area", value: geohash.isEmpty ? "not set" : "\(geohash) (about 1 km)")
            Label(plateStatus.text, systemImage: plateStatus.icon).foregroundStyle(plateStatus.color)
            if !geohash.isEmpty { Button("Clear location", role: .destructive) { set(nil) } }
            Text("Only the 1 km area is stored — not the exact point. Public feeds use each camera's own position.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .onAppear { finder.onFix = { lat, lon in set((lat, lon)) } }
    }

    private var plateStatus: (text: String, icon: String, color: Color) {
        if geohash.isEmpty { return ("Plate reading is off: no location set.", "xmark.circle", .orange) }
        return HubController.platesAllowed(forGeohash6: geohash)
            ? ("Plate reading may run here (redaction rules still apply).", "checkmark.circle.fill", .green)
            : ("Plate reading is off here: within 30 km of a state that restricts it, or outside the US. See docs/PLATE-READING-JURISDICTIONS.md.", "hand.raised.fill", .red)
    }

    private func applyCoordinates() {
        let parts = coordinates.split(whereSeparator: { ", \t;".contains($0) }).compactMap { Double($0) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else {
            message = "Enter latitude then longitude as two numbers, e.g. 44.9778, -93.2650."; return
        }
        set((parts[0], parts[1]))
    }

    private func applyPlusCode() {
        let code = plusCode.split(separator: " ").first.map(String.init) ?? plusCode      // "86P8WQ3M+8Q Minneapolis" → code only
        if let area = PlusCode.decode(code) { set((area.latitude, area.longitude)); return }
        if PlusCode.isShort(code) {
            // A short code needs a nearby reference: use the saved area if there is one.
            if let ref = Geohash.decodeCenter(geohash), let area = PlusCode.decodeShort(code, nearLatitude: ref.latitude, longitude: ref.longitude) {
                set((area.latitude, area.longitude)); return
            }
            message = "That is a short code. Set a nearby location first (or use the full code with the 8-character prefix)."; return
        }
        message = "That is not a valid Plus Code."
    }

    private func set(_ point: (Double, Double)?) {
        message = ""
        if let (lat, lon) = point {
            geohash = Geohash.encode(latitude: lat, longitude: lon, precision: 6)
            coordinates = ""; plusCode = ""
        } else { geohash = "" }
        hub.homeGeohash6 = geohash
    }
}
