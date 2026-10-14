import CryptoKit
import Foundation
import PlateKit

/// Importers for public camera catalogues other than Socrata (see docs/FEED-SOURCES.md and docs/research/more-sources).
/// Every imported source is **unconfirmed** (`automatedUseAllowed == false`): nothing is fetched from its image host until a
/// person reads the operator's terms and confirms them. The importers only read a catalogue — they never touch image URLs.
public enum CameraCatalogueImporters {

    /// Who operates a catalogue and what its licence is believed to be (a hint for the review sheet, never a confirmation).
    public struct Operator: Sendable {
        public var datasetURL: URL
        public var attribution: String
        public var licenseClass: FeedTerms.LicenseClass
        public var refreshInterval: TimeInterval
        public var retrievedAt: Date
        public init(datasetURL: URL, attribution: String, licenseClass: FeedTerms.LicenseClass,
                    refreshInterval: TimeInterval = 300, retrievedAt: Date = Date()) {
            self.datasetURL = datasetURL; self.attribution = attribution
            self.licenseClass = licenseClass; self.refreshInterval = refreshInterval; self.retrievedAt = retrievedAt
        }
    }

    public enum ImportError: Error, Equatable { case malformed(String) }

    // MARK: ArcGIS FeatureServer (WSDOT, Iowa DOT, Newfoundland & Labrador, …)

    public struct ArcGISFields: Sendable {
        public var name: String, image: String, id: String
        /// Use the feature geometry (x = lon, y = lat) when nil; otherwise read these attribute names.
        public var latitude: String?, longitude: String?
        public init(name: String, image: String, id: String, latitude: String? = nil, longitude: String? = nil) {
            self.name = name; self.image = image; self.id = id; self.latitude = latitude; self.longitude = longitude
        }
    }

    /// `data` is one `…/query?f=json&outSR=4326` response. `exceededTransferLimit` tells the caller to fetch the next page.
    public static func arcGIS(_ data: Data, fields: ArcGISFields, operator op: Operator) throws -> (result: SocrataImportResult, hasMore: Bool) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let features = root["features"] as? [[String: Any]] else { throw ImportError.malformed("no features array") }
        var sources: [PublicFeedSource] = [], skipped: [SkipReason] = [], seen = Set<String>()
        for f in features {
            let attrs = f["attributes"] as? [String: Any] ?? [:]
            let geometry = f["geometry"] as? [String: Any]
            let id = Self.string(attrs[fields.id]) ?? ""
            let lat = fields.latitude.flatMap { Self.double(attrs[$0]) } ?? Self.double(geometry?["y"])
            let lon = fields.longitude.flatMap { Self.double(attrs[$0]) } ?? Self.double(geometry?["x"])
            switch build(id: id, name: Self.string(attrs[fields.name]), image: Self.string(attrs[fields.image]),
                         lat: lat, lon: lon, operator: op, seen: &seen) {
            case .success(let s): sources.append(s)
            case .failure(let reason): skipped.append(reason)
            }
        }
        return (SocrataImportResult(sources: sources, skippedCount: skipped.count, skipReasons: skipped),
                (root["exceededTransferLimit"] as? Bool) ?? false)
    }

    // MARK: Caltrans CWWP2 (one JSON per district)

    public static func caltrans(_ data: Data, district: Int, operator op: Operator) throws -> SocrataImportResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["data"] as? [[String: Any]] else { throw ImportError.malformed("no data array") }
        var sources: [PublicFeedSource] = [], skipped: [SkipReason] = [], seen = Set<String>()
        for row in rows {
            guard let cam = row["cctv"] as? [String: Any] else { continue }
            let loc = cam["location"] as? [String: Any] ?? [:]
            let image = (cam["imageData"] as? [String: Any])?["static"] as? [String: Any]
            let id = "D\(district)-\(Self.string(cam["index"]) ?? "")"
            guard (cam["inService"] as? String)?.lowercased() == "true" else {
                skipped.append(SkipReason(cameraID: id, reason: .notTurnedOn)); continue
            }
            switch build(id: id, name: Self.string(loc["locationName"]), image: Self.string(image?["currentImageURL"]),
                         lat: Self.double(loc["latitude"]), lon: Self.double(loc["longitude"]), operator: op, seen: &seen) {
            case .success(let s): sources.append(s)
            case .failure(let reason): skipped.append(reason)
            }
        }
        return SocrataImportResult(sources: sources, skippedCount: skipped.count, skipReasons: skipped)
    }

    // MARK: DriveBC (BC Ministry of Transportation)

    public static func driveBC(_ data: Data, operator op: Operator) throws -> SocrataImportResult {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = root["webcams"] as? [[String: Any]] ?? (root["results"] as? [[String: Any]]) else {
            throw ImportError.malformed("no webcams array")
        }
        var sources: [PublicFeedSource] = [], skipped: [SkipReason] = [], seen = Set<String>()
        for row in rows {
            let id = Self.string(row["id"]) ?? ""
            guard (row["is_on"] as? Bool) ?? false else { skipped.append(SkipReason(cameraID: id, reason: .notTurnedOn)); continue }
            let coords = (row["location"] as? [String: Any])?["coordinates"] as? [Double]
            var image = (row["links"] as? [String: Any]).flatMap { Self.string($0["imageDisplay"]) }
            if let i = image, i.hasPrefix("/") { image = "https://www.drivebc.ca" + i }
            switch build(id: id, name: Self.string(row["name"]), image: image,
                         lat: coords.flatMap { $0.count == 2 ? $0[1] : nil }, lon: coords.flatMap { $0.count == 2 ? $0[0] : nil },
                         operator: op, seen: &seen) {
            case .success(let s): sources.append(s)
            case .failure(let reason): skipped.append(reason)
            }
        }
        return SocrataImportResult(sources: sources, skippedCount: skipped.count, skipReasons: skipped)
    }

    // MARK: Shared

    private static func build(id: String, name: String?, image: String?, lat: Double?, lon: Double?,
                              operator op: Operator, seen: inout Set<String>) -> Result<PublicFeedSource, SkipReason> {
        guard !id.isEmpty else { return .failure(.init(cameraID: "(missing)", reason: .missingCameraID)) }
        guard seen.insert(id).inserted else { return .failure(.init(cameraID: id, reason: .duplicateCameraID)) }
        guard let image, !image.isEmpty, image != "Not Reported" else { return .failure(.init(cameraID: id, reason: .missingImageURL)) }
        guard let url = URL(string: image), let host = url.host, !host.isEmpty else { return .failure(.init(cameraID: id, reason: .invalidImageURL)) }
        guard url.scheme?.lowercased() == "https" else { return .failure(.init(cameraID: id, reason: .nonHTTPSURL)) }
        guard let lat, let lon else { return .failure(.init(cameraID: id, reason: .missingCoordinates)) }
        guard lat != 0 || lon != 0 else { return .failure(.init(cameraID: id, reason: .zeroCoordinates)) }
        guard (-90...90).contains(lat), (-180...180).contains(lon) else { return .failure(.init(cameraID: id, reason: .invalidCoordinates)) }
        let trimmed = (name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            return .success(try PublicFeedSource(
                id: stableUUID(op.datasetURL, id),
                name: trimmed.isEmpty ? "Camera \(id)" : trimmed,
                url: url, kind: .snapshotJPEG, refreshInterval: op.refreshInterval,
                geohash6: Geohash.encode(latitude: lat, longitude: lon, precision: 6),
                citation: SourceCitation(sourceType: .openDataPortal, url: op.datasetURL, retrievedAt: op.retrievedAt),
                termsNote: "",
                terms: FeedTerms(licenseClass: op.licenseClass, attribution: op.attribution, automatedUseAllowed: false),
                nativeLongSide: nil, locationConfidence: .surveyed))
        } catch { return .failure(.init(cameraID: id, reason: .refreshIntervalTooAggressive)) }
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
    private static func stableUUID(_ dataset: URL, _ id: String) -> UUID {
        let b = Array(SHA256.hash(data: Data("\(dataset.absoluteString)|\(id)".utf8)).prefix(16))
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

extension SkipReason: Error {}
