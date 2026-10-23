import CloudKit
import Foundation
import Security

/// Backend selection that cannot crash: `CKContainer(identifier:)` *traps*
/// when the running binary lacks the iCloud container entitlement (unsigned
/// simulator builds, profiles without the container, unprovisioned dev).
/// We read the entitlement list first and only construct CloudKit when the
/// container is actually declared.
public enum SyncBackends {

    public enum Destination: String, CaseIterable, Sendable {
        case automatic
        case cloudKit
        case referenceServer
    }

    public static let containerID = "iCloud.org.platewatch.platewatch"

    /// True when the app's signature declares our CloudKit container.
    public static func cloudKitAvailable(containerID: String = containerID) -> Bool {
#if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let raw = SecTaskCopyValueForEntitlement(task,
                "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        // Entitlement is an array of container strings.
        if let list = raw as? [String] {
            return list.contains(containerID) || list.contains(where: { $0.hasSuffix(containerID) })
        }
        return false
#else
        // iOS/watchOS: runtime entitlement probes are unreliable (and
        // `CKContainer(identifier:)` traps when unentitled), so entitled
        // builds opt in via Info.plist. Unsigned/simulator/CLI builds and
        // targets without the capability simply omit the key and get REST.
        return Bundle.main.object(forInfoDictionaryKey: "PlateWatchUseCloudKit") as? Bool == true
#endif
    }

    /// The right backend for this binary, right now.
    /// - Entitled build  → CloudKit public DB (production path)
    /// - Otherwise       → REST to the configurable mirror (dev default:
    ///   localhost:8083 where `server/` runs). Never nil, never crashes.
    /// Presence, REST and diagnostics all resolve the server through `mirrorURL`, so one saved address serves every feature.
    public static func makeDefault(destination: Destination = .automatic) -> any SyncBackend {
        if destination != .referenceServer && cloudKitAvailable() {
            return CloudKitBackend()
        }
        return RESTBackend(baseURL: mirrorURL())
    }

    /// The backend honoring the user's saved in-app choice (`SyncSettings`).
    /// Read at launch; changing the setting takes effect on the next launch.
    public static func makeConfigured(settings: SyncSettings = .load()) -> any SyncBackend {
        if settings.destination != .referenceServer && cloudKitAvailable() {
            return CloudKitBackend()
        }
        return RESTBackend(baseURL: mirrorURL(override: nil, stored: settings.mirrorURL))
    }

    /// Resolution order: environment override (developer builds) → saved in-app
    /// mirror URL → the local reference-server default. Invalid values fall back
    /// safely; plaintext remote servers and embedded credentials are refused.
    public static func mirrorURL(override: String? = ProcessInfo.processInfo.environment["PLATEWATCH_MIRROR_URL"],
                                 stored: String? = SyncSettings.load().mirrorURL) -> URL {
        if let override, let url = validatedMirrorURL(override) { return url }
        if let stored, let url = validatedMirrorURL(stored) { return url }
        return defaultMirrorURL
    }

    public static let defaultMirrorURL = URL(string: "http://127.0.0.1:8083")!

    /// Returns the URL only when it is safe to send submissions to: https, or http to loopback.
    public static func validatedMirrorURL(_ text: String) -> URL? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              let host = url.host, !host.isEmpty,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host))
        else { return nil }
        return url
    }

}

/// User-chosen backend settings, persisted in `UserDefaults` (never Keychain: it holds no
/// secrets — `validatedMirrorURL` refuses embedded credentials and query tokens).
public struct SyncSettings: Equatable, Sendable {
    public static let destinationKey = "PlateWatchBackendDestination"
    public static let mirrorURLKey = "PlateWatchMirrorURL"

    public var destination: SyncBackends.Destination
    /// Raw text as saved; validated again on every use.
    public var mirrorURL: String?

    public init(destination: SyncBackends.Destination = .automatic, mirrorURL: String? = nil) {
        self.destination = destination
        self.mirrorURL = mirrorURL
    }

    public static func load(_ defaults: UserDefaults = .standard) -> SyncSettings {
        SyncSettings(
            destination: defaults.string(forKey: destinationKey).flatMap(SyncBackends.Destination.init(rawValue:)) ?? .automatic,
            mirrorURL: defaults.string(forKey: mirrorURLKey))
    }

    /// Saves valid settings. A blank URL clears the override; an invalid one throws and saves nothing.
    public func save(_ defaults: UserDefaults = .standard) throws {
        let trimmed = (mirrorURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, SyncBackends.validatedMirrorURL(trimmed) == nil { throw SyncSettingsError.unsafeMirrorURL }
        defaults.set(destination.rawValue, forKey: Self.destinationKey)
        if trimmed.isEmpty { defaults.removeObject(forKey: Self.mirrorURLKey) }
        else { defaults.set(trimmed, forKey: Self.mirrorURLKey) }
    }
}

public enum SyncSettingsError: Error, LocalizedError, Sendable {
    case unsafeMirrorURL
    public var errorDescription: String? {
        "Use an https:// address, or http:// only for this device (localhost). Addresses with a password or query string are refused."
    }
}
