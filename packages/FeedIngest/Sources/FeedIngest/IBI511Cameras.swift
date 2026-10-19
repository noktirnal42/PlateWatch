import Foundation
import PlateKit

/// The "IBI 511" camera schema shared by Nevada, Arizona and Utah's 511 deployments: one camera has several
/// `Views`, each with a snapshot `Url` and sometimes a `VideoUrl` (HLS). The API key authorises only the catalogue
/// request; every imported media host still awaits its own human terms review.
enum IBI511 {
    struct Config {
        var state: String
        var label: String
        var attribution: String
    }

    static func sources(fromJSON data: Data, key: String, config: Config, endpointURL: URL,
                        refreshInterval: TimeInterval = 300, retrievedAt: Date = Date()) throws -> SocrataImportResult {
        guard !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw AZ511Cameras.ImportError.missingKey }
        guard let root = try? JSONSerialization.jsonObject(with: data),
              let cameras = (root as? [[String: Any]])
                ?? (root as? [String: Any])?["cameras"] as? [[String: Any]] else {
            throw AZ511Cameras.ImportError.malformed("expected a camera array")
        }
        var sources: [PublicFeedSource] = []
        var skipped: [SkipReason] = []
        var seen = Set<UUID>()
        for camera in cameras {
            guard let cameraID = identifier(camera["Id"]), !cameraID.isEmpty else {
                skipped.append(.init(cameraID: "(no id)", reason: .missingCameraID)); continue
            }
            guard let lat = number(camera["Latitude"]), let lon = number(camera["Longitude"]),
                  lat.isFinite, lon.isFinite, (-90...90).contains(lat), (-180...180).contains(lon),
                  lat != 0 || lon != 0 else {
                skipped.append(.init(cameraID: cameraID, reason: .missingCoordinates)); continue
            }
            let roadway = (camera["Roadway"] as? String ?? "Camera \(cameraID)").trimmingCharacters(in: .whitespacesAndNewlines)
            let views = camera["Views"] as? [[String: Any]] ?? []
            for view in views {
                guard (view["Status"] as? String)?.lowercased() == "enabled",
                      let viewID = identifier(view["Id"]) else { continue }
                let description = (view["Description"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                let name = description.isEmpty || description == roadway ? roadway : "\(roadway) — \(description)"
                for (field, kind) in [("Url", PublicFeedSource.Kind.snapshotJPEG), ("VideoUrl", .hls)] {
                    guard let text = view[field] as? String, !text.isEmpty else { continue }
                    guard let url = URL(string: text), let host = url.host, !host.isEmpty,
                          url.user == nil, url.password == nil else {
                        skipped.append(.init(cameraID: cameraID, reason: .invalidImageURL)); continue
                    }
                    guard url.scheme?.lowercased() == "https" else {
                        skipped.append(.init(cameraID: cameraID, reason: .nonHTTPSURL)); continue
                    }
                    guard kind != .hls || url.pathExtension.lowercased() == "m3u8" else {
                        skipped.append(.init(cameraID: cameraID, reason: .invalidImageURL)); continue
                    }
                    let id = AZ511Cameras.stableUUID(endpointURL, "\(cameraID)|\(viewID)|\(kind.rawValue)")
                    guard seen.insert(id).inserted else { continue }
                    sources.append(try PublicFeedSource(
                        id: id, name: name + (kind == .hls ? " · HLS" : " · Snapshot"),
                        url: url, kind: kind, refreshInterval: refreshInterval,
                        geohash6: Geohash.encode(latitude: lat, longitude: lon, precision: 6),
                        citation: .init(sourceType: .openDataPortal, url: endpointURL, retrievedAt: retrievedAt),
                        termsNote: "\(config.label) catalogue; media-host terms require separate review.", state: config.state,
                        terms: .init(licenseClass: .unknown, attribution: config.attribution, automatedUseAllowed: false),
                        locationConfidence: .surveyed))
                }
            }
        }
        return .init(sources: sources, skippedCount: skipped.count, skipReasons: skipped)
    }

    private static func identifier(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }
    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value) }
        return nil
    }
}
