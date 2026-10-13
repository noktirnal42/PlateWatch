import Charts
import PlateKit
import PlateSync
import SwiftUI

/// Agency-level public aggregate explorer (M4). Reads the k-anonymous
/// `/v1/aggregates/heatmap` feed — never individual movement, never
/// sub-k buckets. CloudKit deployments surface an explanatory note since
/// aggregates are a REST-mirror capability.
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
                        ContentUnavailableView(
                            "No published buckets",
                            systemImage: "map",
                            description: Text("Every bucket is under k = \(aggregate.k) sightings right now — nothing publishable, nothing leaked."))
                            .listRowBackground(Color.clear)
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

    private static func parseDay(_ raw: String) -> Date {
        dayParser.date(from: raw) ?? Date(timeIntervalSince1970: 0)
    }

    private func load() async {
        loading = true
        defer { loading = false }
        errorText = nil
        do {
            aggregate = try await backend.heatmap(since: nil, until: nil)
        } catch SyncError.unsupported {
            errorText = "Aggregates come from the REST mirror (PLATEWATCH_MIRROR_URL). CloudKit deployments publish nightly exports instead."
        } catch {
            errorText = "Aggregate unavailable: \(error.localizedDescription)"
        }
    }
}
