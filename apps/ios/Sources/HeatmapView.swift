import Charts
import MapKit
import PlateKit
import PlateSync
import SwiftUI

/// Agency-level public aggregate explorer (M4). Reads the k-anonymous
/// `/v1/aggregates/heatmap` feed — never individual movement, never
/// sub-k buckets. On CloudKit the aggregate is computed on-device from the
/// public sightings feed with the same k threshold.
struct HeatmapView: View {
    @Environment(\.syncBackend) private var backend
    @State private var aggregate: HeatmapAggregateDTO?
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        NavigationStack {
            List {
                if let aggregate {
                    Section("Coverage") {
                        LabeledContent("Window") {
                            Text("\(aggregate.since, format: .dateTime.month().day()) – \(aggregate.until, format: .dateTime.month().day())")
                        }
                        LabeledContent("k-anonymity") {
                            Text("k = \(aggregate.k)")
                        }
                        if aggregate.withheldCells > 0 || aggregate.withheldDays > 0 {
                            LabeledContent("Suppressed") {
                                Text("\(aggregate.withheldCells) cells · \(aggregate.withheldDays) days under k")
                            }
                            .foregroundStyle(.secondary)
                        }
                    }

                    if !aggregate.cells.isEmpty {
                        Section {
                            Map(initialPosition: Self.region(for: aggregate.cells)) {
                                ForEach(aggregate.cells, id: \.geohash6) { cell in
                                    if let c = Geohash.decodeCenter(cell.geohash6) {
                                        MapCircle(center: CLLocationCoordinate2D(latitude: c.latitude, longitude: c.longitude),
                                                  radius: 320)
                                            .foregroundStyle(PWStyle.fleet.opacity(0.35))
                                            .stroke(PWStyle.fleet, lineWidth: 1.5)
                                    }
                                }
                            }
                            .frame(height: 260)
                            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                            .listRowInsets(EdgeInsets())
                            .accessibilityLabel("Map of \(aggregate.cells.count) public activity areas")
                        } footer: {
                            Text("Areas are about 1 km wide and only appear once at least \(aggregate.k) fleet-confirmed sightings fall inside them.")
                        }
                    }

                    if !aggregate.timeline.isEmpty {
                        Section("Fleet-confirmed sightings per day") {
                            Chart(aggregate.timeline, id: \.date) { day in
                                BarMark(
                                    x: .value("Day", Self.parseDay(day.date), unit: .day),
                                    y: .value("Sightings", day.count)
                                )
                                .foregroundStyle(PWStyle.fleet.gradient)
                            }
                            .frame(height: 160)
                        }
                    }

                    if !aggregate.cells.isEmpty {
                        Section("~1 km buckets (geohash-6)") {
                            ForEach(aggregate.cells, id: \.geohash6) { cell in
                                HStack {
                                    Text(cell.geohash6)
                                        .font(.body.monospaced())
                                    Spacer()
                                    Text("\(cell.count)")
                                        .font(.headline)
                                        .foregroundStyle(PWStyle.fleet)
                                }
                            }
                        }
                    } else {
                        Section {
                            PWEmptyState(
                                title: "Nothing to show yet",
                                message: "Public activity appears here once at least \(aggregate.k) fleet-confirmed sightings fall in the same area. Smaller counts are withheld to protect privacy.",
                                systemImage: "map")
                                .listRowBackground(Color.clear)
                                .listRowSeparator(.hidden)
                        }
                    }
                } else if let errorText {
                    Section {
                        Label(errorText, systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                } else if loading {
                    Section {
                        HStack {
                            ProgressView()
                            Text("Loading public aggregate…")
                        }
                    }
                }
            }
            .navigationTitle("Explore")
            .refreshable { await load() }
            .task { await load() }
        }
    }

    private static let dayParser: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func region(for cells: [HeatmapAggregateDTO.Cell]) -> MapCameraPosition {
        let points = cells.compactMap { Geohash.decodeCenter($0.geohash6) }
        guard let first = points.first else { return .automatic }
        let lats = points.map(\.latitude), lons = points.map(\.longitude)
        let center = CLLocationCoordinate2D(latitude: (lats.min()! + lats.max()!) / 2,
                                            longitude: (lons.min()! + lons.max()!) / 2)
        let span = MKCoordinateSpan(latitudeDelta: max(0.03, (lats.max()! - lats.min()!) * 1.6),
                                    longitudeDelta: max(0.03, (lons.max()! - lons.min()!) * 1.6))
        _ = first
        return .region(MKCoordinateRegion(center: center, span: span))
    }

    private static func parseDay(_ raw: String) -> Date {
        dayParser.date(from: raw) ?? Date(timeIntervalSince1970: 0)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        errorText = nil
        do {
            aggregate = try await backend.heatmap(since: nil, until: nil)
        } catch {
            errorText = "Public activity couldn’t be loaded right now. Pull to refresh, or check your connection."
        }
    }
}
