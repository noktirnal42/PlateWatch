import FeedIngest
import SwiftUI

/// Guided terms review for one image host. Four steps, top to bottom, nothing hidden:
/// open the operator's terms → record where you read them → pick the licence → confirm.
/// Fields are prefilled from the catalogue (dataset page, licence, attribution) but a person still has to read the
/// terms and tick the box — there is no automatic confirmation.
struct TermsReviewSheet: View {
    @ObservedObject var hub: HubController
    let host: FeedHostSummary
    let sample: PublicFeedSource?
    var onDone: () -> Void

    @State private var termsURL = ""
    @State private var licenseClass: FeedTerms.LicenseClass = .publicDomain
    @State private var attribution = ""
    @State private var haveRead = false
    @State private var error: String?

    private let classes: [(FeedTerms.LicenseClass, String)] = [
        (.publicDomain, "Public domain — the operator says anyone may use the images"),
        (.openLicence, "Open licence (e.g. CC BY) — needs attribution"),
        (.keyed, "Free with a key / registration"),
        (.permissioned, "Written permission from the operator — needs attribution")]

    private var termsIsHTTPS: Bool {
        guard let u = URL(string: termsURL), u.scheme?.lowercased() == "https", u.host?.isEmpty == false else { return false }
        return true
    }
    private var needsAttribution: Bool { licenseClass == .openLicence || licenseClass == .permissioned }
    private var canConfirm: Bool {
        haveRead && termsIsHTTPS && (!needsAttribution || !attribution.trimmingCharacters(in: .whitespaces).isEmpty)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Review terms for \(host.host)").font(.title3.bold())
                    Text("\(host.totalCount) camera\(host.totalCount == 1 ? "" : "s") use this host. Confirming applies to all of them.")
                        .foregroundStyle(.secondary).font(.callout)
                }
                Spacer()
            }.padding()
            Divider()
            Form {
                Section("1 · Read the operator's terms, then record where") {
                    HStack {
                        Button("Open \(host.host)") { open("https://\(host.host)/") }
                        if let page = sample?.citation.url, page.scheme == "https" {
                            Button("Open dataset page") { open(page.absoluteString); if termsURL.isEmpty { termsURL = page.absoluteString } }
                        }
                    }
                    TextField("Terms page you read (https://…)", text: $termsURL)
                    if !termsURL.isEmpty && !termsIsHTTPS { Text("Must be an https:// address.").font(.caption).foregroundStyle(.red) }
                    HStack {
                        Button("Open it") { open(termsURL) }.disabled(!termsIsHTTPS)
                        if let page = sample?.citation.url, page.scheme == "https", termsURL != page.absoluteString {
                            Button("Use dataset page") { termsURL = page.absoluteString }
                        }
                    }
                    Text("Look for terms of use, the licence, and whether automated access is allowed.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("2 · Licence") {
                    Picker("Licence class", selection: $licenseClass) {
                        ForEach(classes, id: \.0) { Text($0.1).tag($0.0) }
                    }.pickerStyle(.radioGroup).labelsHidden()
                    TextField(needsAttribution ? "Attribution (required)" : "Attribution (optional)", text: $attribution)
                }
            }
            .formStyle(.grouped)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("3 · I read these terms and automated analysis of these camera images is permitted.", isOn: $haveRead)
                    .fontWeight(.semibold)
                Text("Nothing is fetched from this host until you confirm. Afterwards the Hub polls politely (one request per camera per refresh interval), honours robots.txt and backs off on errors. You can revoke at any time.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                if let error { Text(error).foregroundStyle(.red).font(.caption) }
            }.padding([.horizontal, .top])
            HStack {
                if host.confirmedCount > 0 {
                    Button("Revoke confirmation", role: .destructive) {
                        do { try hub.revokeFeedTerms(host: host.host); onDone() } catch { self.error = error.localizedDescription }
                    }
                }
                Spacer()
                Button("Cancel") { onDone() }.keyboardShortcut(.cancelAction)
                Button("Confirm \(host.totalCount) camera\(host.totalCount == 1 ? "" : "s")") { confirm() }
                    .buttonStyle(HUDProminentButtonStyle()).disabled(!canConfirm).keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 640, height: 620)
        .onAppear {
            if let s = sample {
                licenseClass = s.terms.licenseClass
                attribution = s.terms.attribution ?? ""
            }
        }
    }

    private func open(_ s: String) { if let u = URL(string: s) { NSWorkspace.shared.open(u) } }

    private func confirm() {
        guard let url = URL(string: termsURL) else { return }
        do {
            try hub.confirmFeedTerms(host: host.host, licenseClass: licenseClass, termsURL: url,
                                     attribution: attribution.trimmingCharacters(in: .whitespacesAndNewlines))
            onDone()
        } catch { self.error = error.localizedDescription }
    }
}
