import PlateKit
import PlateSync
import SwiftUI

/// First-run explanation of what PlateWatch is — and is not. The legal and
/// ethical model is the product's differentiator, so it comes before any
/// permission prompt.
struct OnboardingView: View {
    let onContinue: () -> Void

    var body: some View {
        ZStack {
            Color("LaunchBackground").ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    Image("LaunchLogo")
                        .resizable().scaledToFit()
                        .frame(width: 96, height: 96)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("PlateWatch")
                            .font(.largeTitle.weight(.bold))
                        Text("Hold taxpayer-funded vehicles accountable — police, fire, transit, public works and government fleets.")
                            .font(.title3)
                            .foregroundStyle(.white.opacity(0.78))
                    }
                    principle("lock.shield.fill", "On-device analysis",
                              "Camera frames are read on your iPhone. Raw video never leaves it.")
                    principle("building.columns.fill", "Fleet vehicles only",
                              "Private-citizen plates are dropped before anything is saved or shared.")
                    principle("doc.text.magnifyingglass", "Public records, with sources",
                              "Agency details come from public fleet records and always carry a citation.")
                    principle("hand.raised.fill", "Your location stays coarse",
                              "Sightings are bucketed to about 1 km unless a vehicle is fleet-confirmed.")
                    Button(action: onContinue) {
                        Text("Get started")
                            .font(.headline)
                            .foregroundStyle(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .background(PWStyle.fleet, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .padding(.top, 8)
                    Text("You’ll be asked for camera and location access next. Both are optional — you can import photos instead.")
                        .font(.footnote)
                        .foregroundStyle(.white.opacity(0.6))
                }
                .padding(24)
                .frame(maxWidth: 560)
            }
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
    }

    private func principle(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(PWStyle.fleet)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(.white.opacity(0.7))
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// About + diagnostics: which backend is live, what analyzers are active,
/// and where the rules live. Nothing here is a developer string.
struct SettingsView: View {
    @Environment(\.syncBackend) private var backend

    private var backendName: String {
        backend is CloudKitBackend ? "iCloud (CloudKit public database)" : "Self-hosted server"
    }
    private var version: String {
        let info = Bundle.main.infoDictionary
        return "\(info?["CFBundleShortVersionString"] as? String ?? "0") (\(info?["CFBundleVersion"] as? String ?? "0"))"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("Sync") {
                    LabeledContent("Shared database") { Text(backendName).multilineTextAlignment(.trailing) }
                    LabeledContent("Analysis") {
                        Text(PassiveCaptureStatus.shared.modelStatus == "baseline vision"
                             ? "Apple Vision (on-device)" : PassiveCaptureStatus.shared.modelStatus)
                            .multilineTextAlignment(.trailing)
                    }
                }
                Section("Principles") {
                    Label("Fleet vehicles only", systemImage: "building.columns")
                    Label("On-device analysis, no tracking", systemImage: "lock.shield")
                    Label("Public records only, always cited", systemImage: "doc.text.magnifyingglass")
                }
                Section("Learn more") {
                    Link(destination: URL(string: "https://noktirnal42.github.io/PlateWatch/")!) {
                        Label("Project website", systemImage: "safari")
                    }
                    Link(destination: URL(string: "https://github.com/noktirnal42/PlateWatch/blob/main/docs/LEGAL-ETHICS.md")!) {
                        Label("Legal & ethics", systemImage: "scale.3d")
                    }
                    Link(destination: URL(string: "https://github.com/noktirnal42/PlateWatch")!) {
                        Label("Source code (AGPL-3.0)", systemImage: "chevron.left.forwardslash.chevron.right")
                    }
                }
                Section {
                    LabeledContent("Version") { Text(version) }
                } footer: {
                    Text("PlateWatch is pre-alpha. Detection quality is still being tuned.")
                }
            }
            .navigationTitle("About")
        }
    }
}
