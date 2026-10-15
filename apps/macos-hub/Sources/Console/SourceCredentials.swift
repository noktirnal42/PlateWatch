import Foundation
import Security
import SwiftUI

/// Per-source API credentials for catalogue providers whose supported access
/// route requires a developer key (docs/research/USA-FEEDS-2026-10-14.md).
/// Keys live in the macOS Keychain only — never UserDefaults, never the repo,
/// never sent to camera image hosts. The catalogue API is the only consumer.
enum SourceCredentials {
    struct Provider: Identifiable, Hashable {
        /// Stable credential id (Keychain account + importer selector).
        let id: String
        let name: String
        /// Where the operator obtains / sets up a key. Shown next to the key
        /// field in Settings so the flow is one click away.
        let signupURL: URL
        let note: String
    }

    static let providers: [Provider] = [
        Provider(id: "az511", name: "Arizona 511",
                 signupURL: URL(string: "https://www.az511.gov/developers/doc")!,
                 note: "Statewide camera catalogue + snapshots; 10 calls / 60 s"),
        Provider(id: "nv511", name: "Nevada 511",
                 signupURL: URL(string: "https://www.nvroads.com/developers/doc")!,
                 note: "Camera catalogue; 10 calls / 60 s"),
        Provider(id: "utah-api", name: "UDOT camera API (Utah)",
                 signupURL: URL(string: "https://udottraffic.utah.gov/developers/doc")!,
                 note: "Full inventory beyond the public GIS import"),
        Provider(id: "cotrip", name: "COtrip (Colorado)",
                 signupURL: URL(string: "https://manage-api.cotrip.org/")!,
                 note: "Data-sharing management portal"),
        Provider(id: "511ny", name: "511NY (New York)",
                 signupURL: URL(string: "https://511ny.org/developers/doc")!,
                 note: "Documented developer programme"),
        Provider(id: "wsdot-api", name: "WSDOT Traveler API (Washington)",
                 signupURL: URL(string: "https://wsdot.com/travel/api")!,
                 note: "Access code unlocks video and full camera data"),
        Provider(id: "ohgo", name: "OHGO (Ohio)",
                 signupURL: URL(string: "https://publicapi.ohgo.com/docs")!,
                 note: "Public API programme"),
    ]

    private static let service = "org.platewatch.hub.sourcekeys"

    static func key(for id: String) -> String? {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: id,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func hasKey(_ id: String) -> Bool { key(for: id) != nil }

    @discardableResult
    static func setKey(_ value: String, for id: String) -> Bool {
        removeKey(for: id)
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        let item: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: service,
                                   kSecAttrAccount as String: id,
                                   kSecValueData as String: Data(trimmed.utf8),
                                   kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
    }

    static func removeKey(for id: String) {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service,
                       kSecAttrAccount as String: id] as CFDictionary)
    }
}

/// One provider row in Settings › Source API keys: key entry with the signup
/// link right next to it, so obtaining the key is one click away. Keys go to
/// the Keychain via `SourceCredentials`; the field is cleared after a save.
struct SourceKeyRow: View {
    let provider: SourceCredentials.Provider

    @State private var draft = ""
    @State private var notice = ""

    var body: some View {
        let stored = SourceCredentials.hasKey(provider.id)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(provider.name).font(.callout.bold())
                if stored {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(.green)
                        .help("A key is stored in this Mac's Keychain")
                }
                Spacer()
                Link(destination: provider.signupURL) {
                    Label("Get a key", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
                .help("Open \(provider.signupURL.absoluteString) to obtain or manage the API key")
            }
            HStack(spacing: 8) {
                SecureField(stored ? "Replace stored key…" : "Paste API key…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                Button("Save") {
                    if SourceCredentials.setKey(draft, for: provider.id) {
                        notice = "Key stored in the Keychain."
                    } else {
                        notice = "Could not store the key (Keychain refused)."
                    }
                    draft = ""
                }
                .disabled(draft.trimmingCharacters(in: .whitespaces).isEmpty)
                if stored {
                    Button("Remove", role: .destructive) {
                        SourceCredentials.removeKey(for: provider.id)
                        notice = "Key removed."
                    }
                }
            }
            Text(provider.note).font(.caption).foregroundStyle(.secondary)
            if !notice.isEmpty {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}
