import CryptoKit
import Foundation
import PlateKit

/// Arizona 511 camera catalogue via the documented IBI 511 API v2
/// (`/api/v2/get/cameras?key=…`). A developer key is required — the operator
/// records it in Settings › Source API keys (signup:
/// <https://www.az511.gov/developers/doc>, 10 calls / 60 s). The key
/// authorises the *catalogue* request only; it is never attached to camera
/// image fetches and never leaves the Keychain except in this one request.
///
/// Status: implemented against the published camera schema; the live response
/// needs a keyed verification pass (no key available offline). The parser is
/// tolerant of the field-case variants IBI deployments ship.
public enum AZ511Cameras {
    public static let apiDocs = URL(string: "https://www.az511.gov/developers/doc")!
    public static let endpoint = URL(string: "https://ibi.az511.gov/api/v2/get/cameras")!

    public enum ImportError: Error, Equatable {
        case missingKey
        case malformed(String)
    }

    public static func sources(fromJSON data: Data, key: String,
                               endpointURL: URL = endpoint,
                               refreshInterval: TimeInterval = 300,
                               retrievedAt: Date = Date()) throws -> SocrataImportResult {
        guard !key.trimmingCharacters(in: .whitespaces).isEmpty else { throw ImportError.missingKey }
        guard let root = try? JSONSerialization.jsonObject(with: data) else {
            throw ImportError.malformed("response is not JSON")
        }
        // IBI v2 deployments return either a bare array or one of the wrapper
        // shapes seen across the family: {"items": [...]}, {"cameras": [...]}.
        let items: [Any]
        if let array = root as? [Any] {
            items = array
        } else if let dict = root as? [String: Any] {
            items = (dict["items"] ?? dict["cameras"] ?? dict["data"]) as? [Any] ?? []
        } else {
            items = []
        }

        // The published schema nests snapshot URLs under `Views` (shared IBI 511 shape). The flat shape below is kept
        // for older fixtures and wrapper variants.
        if items.contains(where: { ($0 as? [String: Any])?["Views"] != nil }) {
            return try IBI511.sources(fromJSON: JSONSerialization.data(withJSONObject: items), key: key,
                                      config: .init(state: "AZ", label: "AZ511", attribution: "Arizona 511 / ADOT"),
                                      endpointURL: endpointURL, refreshInterval: refreshInterval, retrievedAt: retrievedAt)
        }

        var sources: [PublicFeedSource] = []
        var skipped: [SkipReason] = []
        var seen = Set<String>()

        for item in items {
            guard let dict = item as? [String: Any] else { continue }
            let id = Self.string(dict["Id"]) ?? Self.string(dict["id"]) ?? ""
            guard !id.isEmpty else {
                skipped.append(SkipReason(cameraID: "(no id)", reason: .missingCameraID)); continue
            }
            guard seen.insert(id).inserted else { continue }

            guard let imageText = Self.string(dict["Url"]) ?? Self.string(dict["url"])
                    ?? Self.string(dict["ImageUrl"]) ?? Self.string(dict["imageUrl"]),
                  !imageText.isEmpty else {
                skipped.append(SkipReason(cameraID: id, reason: .missingImageURL)); continue
            }
            guard let url = URL(string: imageText), url.host != nil, !url.host!.isEmpty else {
                skipped.append(SkipReason(cameraID: id, reason: .invalidImageURL)); continue
            }
            guard url.scheme?.lowercased() == "https" else {
                skipped.append(SkipReason(cameraID: id, reason: .nonHTTPSURL)); continue
            }
            let lat = Self.double(dict["Latitude"]) ?? Self.double(dict["latitude"])
            let lon = Self.double(dict["Longitude"]) ?? Self.double(dict["longitude"])
            guard let lat, let lon, (-90...90).contains(lat), (-180...180).contains(lon), lat != 0 || lon != 0 else {
                skipped.append(SkipReason(cameraID: id, reason: .missingCoordinates)); continue
            }

            let name = (Self.string(dict["Name"]) ?? Self.string(dict["name"])
                        ?? Self.string(dict["LocalName"]) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            do {
                sources.append(try PublicFeedSource(
                    id: stableUUID(endpointURL, id),
                    name: name.isEmpty ? "AZ511 camera \(id)" : name,
                    url: url, kind: .snapshotJPEG, refreshInterval: refreshInterval,
                    geohash6: Geohash.encode(latitude: lat, longitude: lon, precision: 6),
                    citation: SourceCitation(sourceType: .openDataPortal, url: endpointURL, retrievedAt: retrievedAt),
                    termsNote: "",
                    state: "AZ",
                    terms: FeedTerms(licenseClass: .unknown, attribution: "Arizona 511 / ADOT",
                                     automatedUseAllowed: false),
                    nativeLongSide: nil, locationConfidence: .surveyed))
            } catch {
                skipped.append(SkipReason(cameraID: id, reason: .refreshIntervalTooAggressive))
            }
        }
        return SocrataImportResult(sources: sources, skippedCount: skipped.count, skipReasons: skipped)
    }

    /// Same derivation as the other catalogue importers: the same camera keeps
    /// the same id across re-imports, so human terms decisions survive merges.
    static func stableUUID(_ endpoint: URL, _ id: String) -> UUID {
        let b = Array(SHA256.hash(data: Data("\(endpoint.absoluteString)|\(id)".utf8)).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }

    private static func string(_ v: Any?) -> String? {
        if let s = v as? String { return s }
        if let n = v as? NSNumber { return n.stringValue }
        return nil
    }

    private static func double(_ v: Any?) -> Double? {
        if let d = v as? Double { return d }
        if let s = v as? String { return Double(s) }
        if let n = v as? NSNumber { return n.doubleValue }
        return nil
    }
}
