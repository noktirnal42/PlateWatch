import CloudKit
import Foundation
import Security

/// Backend selection that cannot crash: `CKContainer(identifier:)` *traps*
/// when the running binary lacks the iCloud container entitlement (unsigned
/// simulator builds, profiles without the container, unprovisioned dev).
/// We read the entitlement list first and only construct CloudKit when the
/// container is actually declared.
public enum SyncBackends {

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
    public static func makeDefault() -> any SyncBackend {
        if cloudKitAvailable() {
            return CloudKitBackend()
        }
        return RESTBackend(baseURL: mirrorURL())
    }

    /// Invalid overrides fall back safely; plaintext remote servers and embedded credentials are refused.
    public static func mirrorURL(override: String? = ProcessInfo.processInfo.environment["PLATEWATCH_MIRROR_URL"]) -> URL {
        if let override, let url = URL(string: override),
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
           let host = url.host, !host.isEmpty,
           url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) {
            return url
        }
        return URL(string: "http://127.0.0.1:8083")!
    }

}
