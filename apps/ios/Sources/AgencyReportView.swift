import PlateSync
import SwiftUI

/// Public, aggregate agency accountability reports. The directory and report
/// endpoints never expose individual routes, exact locations or private people.
struct AgencyDirectoryView: View {
    @Environment(\.syncBackend) private var backend
    @State private var agencies: [PublicAgencyDTO] = []
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        List {
            if loading && agencies.isEmpty {
                HStack { ProgressView(); Text("Loading public agencies…") }
            } else if let errorText, agencies.isEmpty {
                ContentUnavailableView("Agency directory unavailable", systemImage: "building.columns",
                                       description: Text(errorText))
            } else if agencies.isEmpty {
                ContentUnavailableView("No public agencies yet", systemImage: "building.columns",
                                       description: Text("The reference server has not published agency records."))
            } else {
                ForEach(agencies) { agency in
                    NavigationLink {
                        AgencyReportDetailView(agency: agency)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(agency.name).font(.headline)
                            Text("\(agency.shortName.map { "\($0) · " } ?? "")\(agency.level.capitalized)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .safeAreaInset(edge: .top) { PreviewBanner() }
        .navigationTitle("Agency reports")
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        guard !PreviewFixtures.isEnabled else {
            errorText = "Public agency reports are disabled in the local demo preview."
            return
        }
        loading = true
        defer { loading = false }
        do { agencies = try await backend.agencies(); errorText = nil }
        catch { errorText = message(for: error) }
    }

    private func message(for error: Error) -> String {
        if case SyncError.unsupported = error { return "This backend does not publish agency report cards yet." }
        return "Pull to retry, or check the backend connection."
    }
}

struct AgencyReportDetailView: View {
    @Environment(\.syncBackend) private var backend
    let agency: PublicAgencyDTO
    @State private var report: AgencyReportDTO?
    @State private var errorText: String?
    @State private var loading = false

    var body: some View {
        List {
            if let report {
                Section {
                    ReportMetric(title: "Known fleet", value: report.fleetSize, icon: "car.2")
                    ReportMetric(title: "Fleet-confirmed sightings · 30 days", value: report.sightings30d, icon: "eye")
                    ReportMetric(title: "Rostered unit numbers", value: report.activeUnits, icon: "number")
                } header: { Text(report.agency.name).font(.headline) }
                Section("Public links") {
                    publicLink("Agency contact", urlString: report.publicContactURL)
                    publicLink("Budget source", urlString: report.budgetURL)
                }
                Section {
                    Label("Aggregated public records only", systemImage: "lock.shield")
                    Text("This card contains counts, not individual movement, exact locations, occupants, or private-person records.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Generated \(report.generatedAt, format: .dateTime.month().day().year().hour().minute())")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            } else if loading {
                HStack { ProgressView(); Text("Loading report…") }
            } else if let errorText {
                ContentUnavailableView("Report unavailable", systemImage: "chart.bar.xaxis",
                                       description: Text(errorText))
            }
        }
        .safeAreaInset(edge: .top) { PreviewBanner() }
        .navigationTitle(agency.shortName ?? "Report card")
        .refreshable { await load() }
        .task { await load() }
    }

    @ViewBuilder
    private func publicLink(_ title: String, urlString: String?) -> some View {
        if let urlString, let url = URL(string: urlString), ["http", "https"].contains(url.scheme?.lowercased()) {
            Link(destination: url) { Label(title, systemImage: "link") }
        } else {
            LabeledContent(title, value: "Not published")
                .foregroundStyle(.secondary)
        }
    }

    private func load() async {
        guard !PreviewFixtures.isEnabled else {
            errorText = "Public agency reports are disabled in the local demo preview."
            return
        }
        loading = true
        defer { loading = false }
        do { report = try await backend.agencyReport(id: agency.id); errorText = nil }
        catch { errorText = "Pull to retry, or check the backend connection." }
    }
}

private struct ReportMetric: View {
    let title: String
    let value: Int
    let icon: String

    var body: some View {
        LabeledContent {
            Text(value.formatted()).font(.title3.weight(.semibold)).foregroundStyle(PWStyle.fleetText)
        } label: {
            Label(title, systemImage: icon)
        }
    }
}
