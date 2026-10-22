import AppKit
import FeedIngest
import MapKit
import PlateKit
import SwiftUI

/// Every catalogue camera on a map. Click a pin to see where it is and open it in Live (same terms and block gates as the
/// list). Positions are the camera's stored geohash-6 centre (about 1 km), so pins are approximate. Idea and pin/card pattern
/// from TrafficView (re-implemented). Nothing leaves the Mac except the map tiles MapKit itself requests.
struct MapPane: View {
    let hub: HubController
    let isActive: Bool
    var onOpenLive: () -> Void

    @ObservedObject private var favorites: FeedFavorites
    @State private var sources: [PublicFeedSource] = []
    @State private var places: [UUID: FeedPlace] = [:]
    @State private var selectedID: UUID?
    @State private var focusRevision = 0
    @State private var style: MapStyle = .hybrid
    @State private var confirmedOnly = false
    private nonisolated static let placeIndex = FeedPlaceIndex()

    enum MapStyle: String, CaseIterable, Identifiable {
        case standard = "Standard", satellite = "Satellite", hybrid = "Hybrid"
        var id: String { rawValue }
    }

    init(hub: HubController, isActive: Bool, onOpenLive: @escaping () -> Void) {
        self.hub = hub; self.isActive = isActive; self.onOpenLive = onOpenLive
        _favorites = ObservedObject(wrappedValue: hub.favorites)
    }

    private var visible: [PublicFeedSource] {
        sources.filter { !favorites.isBlocked($0.id) && (!confirmedOnly || $0.mayBeAnalysed) }
    }
    private var selected: PublicFeedSource? { selectedID.flatMap { id in sources.first { $0.id == id } } }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            CameraMapRepresentable(sources: visible, favorites: favorites.ids, style: style, selectedID: selectedID,
                                   focus: selected.flatMap { Geohash.decodeCenter($0.geohash6) }.map { ($0.latitude, $0.longitude) },
                                   focusRevision: focusRevision) { selectedID = $0 }
            VStack(alignment: .trailing, spacing: 8) {
                HStack(spacing: 10) {
                    Picker("Map style", selection: $style) { ForEach(MapStyle.allCases) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).labelsHidden().frame(width: 230)
                    Toggle("Confirmed only", isOn: $confirmedOnly).toggleStyle(.checkbox)
                        .help("Show only cameras whose image-host terms a person has confirmed")
                }
                .padding(8).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 10))
                Text("\(visible.count.formatted()) cameras · pins are approximate (~1 km)")
                    .font(.caption).padding(.horizontal, 8).padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
            }.padding(14)
            if let source = selected {
                VStack { Spacer(); card(source).frame(maxWidth: 440).padding(14) }.frame(maxWidth: .infinity)
            }
        }
        .onAppear { load(); applyFocus() }
        .onChange(of: isActive) { _, active in if active { load(); applyFocus() } }
        .onChange(of: hub.mapFocus?.token) { _, _ in applyFocus() }
    }

    private func card(_ source: PublicFeedSource) -> some View {
        let state = hub.feedRunner.state(of: source)
        let place = places[source.id]?.label ?? source.state ?? "Unknown"
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.name).font(.headline).lineLimit(2)
                    Text("\(place) · \(source.terms.attribution)").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button { selectedID = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain).help("Close")
            }
            Label(state.text, systemImage: state.icon).font(.caption).foregroundStyle(state.color)
            if !source.mayBeAnalysed {
                Text("Confirm this host's terms in Public feeds → Review terms… to open it.").font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Open in Live", systemImage: "play.rectangle.fill") { hub.openFeedInLive(source); onOpenLive() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!source.mayBeAnalysed || favorites.isBlocked(source.id))
                Button { favorites.toggle(source.id) } label: {
                    Image(systemName: favorites.contains(source.id) ? "star.fill" : "star").foregroundStyle(favorites.contains(source.id) ? Color.yellow : Color.secondary)
                }.help(favorites.contains(source.id) ? "Remove from favorites" : "Add to favorites")
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(CornerBrackets(length: 10).stroke(HubTheme.accent.opacity(0.8), lineWidth: 1.2).padding(3))
    }

    /// "Show on map": select the camera and ask the map to centre and zoom on it (the pin turns amber and is drawn on top).
    private func applyFocus() {
        guard let focus = hub.mapFocus else { return }
        if sources.isEmpty { load() }
        if let source = sources.first(where: { $0.id == focus.id }) {
            confirmedOnly = confirmedOnly && source.mayBeAnalysed
            selectedID = focus.id
            focusRevision += 1
        }
    }

    private func load() {
        let loaded = ((try? FeedCatalogue.load(from: hub.feedsFile))?.sources ?? [])
        sources = loaded
        let missing = loaded.filter { places[$0.id] == nil }
        guard !missing.isEmpty else { return }
        Task.detached(priority: .utility) {
            var found: [UUID: FeedPlace] = [:]
            for s in missing { if let p = Self.placeIndex.place(for: s) { found[s.id] = p } }
            await MainActor.run { places.merge(found) { _, new in new } }
        }
    }
}

final class CameraPin: NSObject, MKAnnotation {
    let sourceID: UUID
    let coordinate: CLLocationCoordinate2D
    let title: String?
    let confirmed: Bool
    init(source: PublicFeedSource, coordinate: CLLocationCoordinate2D) {
        sourceID = source.id; self.coordinate = coordinate; title = source.name; confirmed = source.mayBeAnalysed
    }
}

struct CameraMapRepresentable: NSViewRepresentable {
    let sources: [PublicFeedSource]
    let favorites: Set<UUID>
    let style: MapPane.MapStyle
    let selectedID: UUID?
    let focus: (latitude: Double, longitude: Double)?
    let focusRevision: Int
    let onSelect: (UUID) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onSelect: onSelect) }

    func makeNSView(context: Context) -> MKMapView {
        let map = MKMapView()
        map.delegate = context.coordinator
        map.showsCompass = true; map.showsZoomControls = true; map.showsScale = true
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: "pin")
        map.register(MKMarkerAnnotationView.self, forAnnotationViewWithReuseIdentifier: MKMapViewDefaultClusterAnnotationViewReuseIdentifier)
        map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: 39.5, longitude: -105), span: MKCoordinateSpan(latitudeDelta: 30, longitudeDelta: 45)), animated: false)
        return map
    }

    func updateNSView(_ map: MKMapView, context: Context) {
        let c = context.coordinator
        c.onSelect = onSelect
        c.favorites = favorites
        if c.style != style {
            c.style = style
            switch style {
            case .standard: map.preferredConfiguration = MKStandardMapConfiguration()
            case .satellite: map.preferredConfiguration = MKImageryMapConfiguration()
            case .hybrid: map.preferredConfiguration = MKHybridMapConfiguration()
            }
        }
        let key = "\(sources.count)|\(sources.first?.id.uuidString ?? "")|\(sources.last?.id.uuidString ?? "")|\(sources.filter(\.mayBeAnalysed).count)"
        if key != c.key {
            c.key = key
            map.removeAnnotations(map.annotations.filter { $0 is CameraPin })
            map.addAnnotations(sources.compactMap { source in
                Geohash.decodeCenter(source.geohash6).map { CameraPin(source: source, coordinate: CLLocationCoordinate2D(latitude: $0.latitude, longitude: $0.longitude)) }
            })
        }
        if focusRevision != c.focusRevision, let focus {
            c.focusRevision = focusRevision
            map.setRegion(MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: focus.latitude, longitude: focus.longitude),
                                             latitudinalMeters: 6_000, longitudinalMeters: 6_000), animated: true)
        }
        if selectedID != c.selectedID {
            c.selectedID = selectedID
            for pin in map.annotations.compactMap({ $0 as? CameraPin }) {
                if let view = map.view(for: pin) as? MKMarkerAnnotationView { c.style(view, pin: pin) }
            }
        }
    }

    @MainActor final class Coordinator: NSObject, MKMapViewDelegate {
        var onSelect: (UUID) -> Void
        var style: MapPane.MapStyle?
        var key = ""
        var favorites: Set<UUID> = []
        var selectedID: UUID?
        var focusRevision = -1
        init(onSelect: @escaping (UUID) -> Void) { self.onSelect = onSelect }

        func mapView(_ mapView: MKMapView, viewFor annotation: MKAnnotation) -> MKAnnotationView? {
            guard let pin = annotation as? CameraPin else { return nil }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "pin", for: pin) as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: pin, reuseIdentifier: "pin")
            view.annotation = pin
            view.clusteringIdentifier = "camera"
            view.canShowCallout = false
            view.glyphImage = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
            style(view, pin: pin)
            return view
        }

        /// Amber and on top for the selected / "Show on map" camera and for favorites; teal when terms are confirmed; gray otherwise.
        func style(_ view: MKMarkerAnnotationView, pin: CameraPin) {
            let selected = pin.sourceID == selectedID
            view.markerTintColor = (selected || favorites.contains(pin.sourceID))
                ? NSColor(srgbRed: 0xF5 / 255, green: 0xB8 / 255, blue: 0x3D / 255, alpha: 1)
                : (pin.confirmed ? NSColor(srgbRed: 0x4F / 255, green: 0xD1 / 255, blue: 0xE0 / 255, alpha: 1) : .systemGray)
            view.zPriority = selected ? .max : .defaultUnselected
            view.displayPriority = selected ? .required : .defaultHigh
            view.clusteringIdentifier = selected ? nil : "camera"
            view.glyphImage = NSImage(systemSymbolName: selected ? "video.circle.fill" : "video.fill", accessibilityDescription: nil)
        }

        /// Name clusters by size ("1,219 cameras") instead of MapKit's default "<first camera> +N more".
        func mapView(_ mapView: MKMapView, clusterAnnotationForMemberAnnotations memberAnnotations: [MKAnnotation]) -> MKClusterAnnotation {
            let cluster = MKClusterAnnotation(memberAnnotations: memberAnnotations)
            cluster.title = "\(memberAnnotations.count.formatted()) cameras"
            cluster.subtitle = nil
            return cluster
        }

        func mapView(_ mapView: MKMapView, didSelect view: MKAnnotationView) {
            if let cluster = view.annotation as? MKClusterAnnotation {
                mapView.deselectAnnotation(cluster, animated: false)
                let points: [MKMapPoint] = cluster.memberAnnotations.map { MKMapPoint($0.coordinate) }
                var rect = MKMapRect.null
                for point in points { rect = rect.union(MKMapRect(origin: point, size: MKMapSize(width: 1, height: 1))) }
                mapView.setVisibleMapRect(rect, edgePadding: NSEdgeInsets(top: 80, left: 80, bottom: 80, right: 80), animated: true)
                return
            }
            guard let pin = view.annotation as? CameraPin else { return }
            mapView.deselectAnnotation(pin, animated: false)
            onSelect(pin.sourceID)
        }
    }
}
