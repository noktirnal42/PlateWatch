import FeedIngest
import SwiftUI

/// View for reviewing and confirming feed terms per image host.
struct FeedsReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var hub: HubController

    @State private var hosts: [FeedHostSummary] = []
    @State private var selectedHost: FeedHostSummary?
    @State private var termsURL: String = ""
    @State private var licenseClass: FeedTerms.LicenseClass = .publicDomain
    @State private var attribution: String = ""
    @State private var iHaveReadTerms = false
    @State private var errorMessage: String?
    @State private var isLoading = false

    private let allowedLicenseClasses: [FeedTerms.LicenseClass] = [.publicDomain, .openLicence, .keyed, .permissioned]

    var body: some View {
        NavigationSplitView {
            // Host list sidebar
            List(hosts, id: \.host, selection: $selectedHost) { summary in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(summary.host)
                            .font(.system(.body, design: .monospaced))
                        Text("\(summary.confirmedCount) of \(summary.totalCount) confirmed")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if summary.confirmedCount == summary.totalCount {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else if summary.confirmedCount > 0 {
                        Image(systemName: "circle.lefthalf.filled")
                            .foregroundStyle(.orange)
                    } else {
                        Image(systemName: "circle")
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 4)
            }
            .navigationTitle("Feed Terms Review")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh") { loadHosts() }
                }
            }
        } detail: {
            // Detail form for selected host
            if let host = selectedHost {
                Form {
                    Section("Host") {
                        Text(host.host)
                            .font(.system(.body, design: .monospaced))
                        Text("\(host.totalCount) camera\(host.totalCount == 1 ? "" : "s") on this host")
                            .foregroundStyle(.secondary)
                    }

                    Section("Terms Confirmation") {
                        TextField("Terms page URL (must be HTTPS)", text: $termsURL)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: termsURL) { _, newValue in
                                errorMessage = validateURL(newValue) ? nil : "URL must be a valid HTTPS URL with a host"
                            }

                        Picker("License Class", selection: $licenseClass) {
                            ForEach(allowedLicenseClasses, id: \.self) { cls in
                                Text(cls.rawValue).tag(cls)
                            }
                        }
                        .pickerStyle(.menu)

                        if licenseClass == .openLicence || licenseClass == .permissioned {
                            TextField("Attribution (required)", text: $attribution)
                                .textFieldStyle(.roundedBorder)
                        } else {
                            TextField("Attribution (optional)", text: $attribution)
                                .textFieldStyle(.roundedBorder)
                        }

                        Toggle("I have read these terms and automated analysis of these feeds is permitted", isOn: $iHaveReadTerms)

                        HStack {
                            Button("Open terms page") {
                                if let url = URL(string: termsURL), validateURL(termsURL) {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                            .disabled(!validateURL(termsURL))

                            Spacer()

                            Button("Confirm all \(host.totalCount) camera\(host.totalCount == 1 ? "" : "s") on this host") {
                                confirmTerms(for: host)
                            }
                            .buttonStyle(HUDProminentButtonStyle())
                            .disabled(!canConfirm)

                            if host.confirmedCount > 0 {
                                Button("Revoke confirmation") {
                                    revokeTerms(for: host)
                                }
                                .buttonStyle(HUDButtonStyle())
                                .foregroundStyle(.red)
                            }
                        }
                    }

                    if let error = errorMessage {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }

                    Section {
                        Text("The person confirming is responsible for having read the operator's terms. No automated confirmation is performed.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .formStyle(.grouped)
                .scrollContentBackground(.hidden)
            } else {
                ContentUnavailableView(
                    "Select a host",
                    systemImage: "doc.text.magnifyingglass",
                    description: Text("Choose an image host from the list to review and confirm its terms.")
                )
            }
        }
        .onAppear { loadHosts() }
        // A confirmation belongs to ONE host and the terms page that person read for it: never carry the ticked box,
        // URL or attribution over to another host (otherwise host B could be confirmed with host A's terms).
        .onChange(of: selectedHost?.host) { _, _ in resetForm() }
        .frame(minWidth: 700, minHeight: 500)
    }

    private func resetForm() {
        termsURL = ""
        attribution = ""
        licenseClass = .publicDomain
        iHaveReadTerms = false
        errorMessage = nil
    }

    private func loadHosts() {
        hosts = hub.feedHosts()
    }

    private func validateURL(_ string: String) -> Bool {
        guard let url = URL(string: string),
              url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty else {
            return false
        }
        return true
    }

    private var canConfirm: Bool {
        guard iHaveReadTerms else { return false }
        guard validateURL(termsURL) else { return false }
        if (licenseClass == .openLicence || licenseClass == .permissioned) {
            return !attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return true
    }

    private func confirmTerms(for host: FeedHostSummary) {
        guard let url = URL(string: termsURL) else {
            errorMessage = "Invalid URL"
            return
        }

        isLoading = true
        errorMessage = nil

        do {
            try hub.confirmFeedTerms(
                host: host.host,
                licenseClass: licenseClass,
                termsURL: url,
                attribution: attribution.trimmingCharacters(in: .whitespacesAndNewlines)
            )
            loadHosts()
            // Keep selection on the same host (now with updated counts)
            selectedHost = hosts.first { $0.host == host.host }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    private func revokeTerms(for host: FeedHostSummary) {
        isLoading = true
        errorMessage = nil

        do {
            try hub.revokeFeedTerms(host: host.host)
        } catch {
            errorMessage = error.localizedDescription
        }
        loadHosts()
        selectedHost = hosts.first { $0.host == host.host }

        isLoading = false
    }
}