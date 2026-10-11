import CloudKit
import Foundation

/// Backend selection that cannot crash: `CKContainer(identifier:)` *traps*
/// when the running binary lacks the iCloud container entitlement (unsigned
/// simulator builds, profiles without the container, unprovisioned dev).
/// We read the entitlement list first and only construct CloudKit when the
/// container is actually declared.
public enum SyncBackends {

    public static let containerID = "iCloud.org.platewatch.platewatch"

    /// True when the app's signature declares our CloudKit container.
    public static func cloudKitAvailable(containerID: String = containerID) -> Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        guard let raw = SecTaskCopyValueForEntitlement(task,
                "com.apple.developer.icloud-container-identifiers" as CFString, nil)
        else { return false }
        // Entitlement is an array of container strings.
        if let list = raw as? [String] {
            return list.contains(containerID) || list.contains(where: { $0.hasSuffix(containerID) })
        }
        return false
    }

    /// The right backend for this binary, right now.
    /// - Entitled build  → CloudKit public DB (production path)
    /// - Otherwise       → REST to the configurable mirror (dev default:
    ///   localhost:8080 where `server/` runs). Never nil, never crashes.
    public static func makeDefault() -> any SyncBackend {
        if cloudKitAvailable() {
            return CloudKitBackend()
        }
        let mirror = ProcessInfo.processInfo.environment["PLATEWATCH_MIRROR_URL"]
            ?? "http://127.0.0.1:8080"
        return RESTBackend(baseURL: URL(string: mirror)!)
    }
}
