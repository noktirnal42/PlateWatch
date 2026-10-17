import CloudKit
import Foundation
import PlateSync

/// Small, read-only connection probe used by the mobile About screen. It
/// distinguishes a configured backend from a backend that can actually answer.
enum BackendDiagnostics {
    static func status(for backend: any SyncBackend) async -> String {
        if let rest = backend as? RESTBackend {
            var request = URLRequest(url: rest.baseURL.appending(path: "health"))
            request.timeoutInterval = 8
            request.cachePolicy = .reloadIgnoringLocalCacheData
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else { return "Server returned an invalid response" }
                guard http.statusCode == 200,
                      let body = try? JSONDecoder().decode([String: String].self, from: data),
                      body["status"] == "ok" else {
                    return "Server unavailable · HTTP \(http.statusCode)"
                }
                return "Connected · \(rest.baseURL.absoluteString)"
            } catch {
                return "Offline · \(rest.baseURL.absoluteString)"
            }
        }

        guard SyncBackends.cloudKitAvailable() else { return "CloudKit entitlement is not active in this build" }
        do {
            let container = CKContainer(identifier: SyncBackends.containerID)
            guard try await container.accountStatus() == .available else {
                return "Sign in to iCloud on this device"
            }
            _ = try await container.userRecordID()
            let query = CKQuery(recordType: "Sighting", predicate: NSPredicate(value: true))
            _ = try await container.publicCloudDatabase.records(matching: query, inZoneWith: nil,
                                                                  desiredKeys: [], resultsLimit: 1)
            return "Connected · CloudKit public database readable"
        } catch {
            let nsError = error as NSError
            return "iCloud account available · database query failed (\(nsError.code))"
        }
    }
}
