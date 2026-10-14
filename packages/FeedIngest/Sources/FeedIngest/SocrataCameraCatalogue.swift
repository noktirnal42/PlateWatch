import Foundation
import CryptoKit
import PlateKit

/// Result of importing a Socrata camera catalogue, including successfully imported sources and skip reasons.
public struct SocrataImportResult: Sendable, Equatable {
    public let sources: [PublicFeedSource]
    public let skippedCount: Int
    public let skipReasons: [SkipReason]

    public init(sources: [PublicFeedSource], skippedCount: Int, skipReasons: [SkipReason]) {
        self.sources = sources
        self.skippedCount = skippedCount
        self.skipReasons = skipReasons
    }
}

/// Reason a record was skipped during import.
public struct SkipReason: Sendable, Equatable, Hashable {
    public let cameraID: String
    public let reason: Reason

    public init(cameraID: String, reason: Reason) {
        self.cameraID = cameraID
        self.reason = reason
    }

    public enum Reason: String, Sendable, Codable, Equatable, Hashable {
        case notTurnedOn = "not_turned_on"
        case missingImageURL = "missing_image_url"
        case invalidImageURL = "invalid_image_url"
        case nonHTTPSURL = "non_https_url"
        case missingCoordinates = "missing_coordinates"
        case invalidCoordinates = "invalid_coordinates"
        case zeroCoordinates = "zero_coordinates"
        case duplicateCameraID = "duplicate_camera_id"
        case refreshIntervalTooAggressive = "refresh_interval_too_aggressive"
    }
}

/// Imports camera catalogues from Socrata open data portals (e.g., City of Austin Traffic Cameras).
public struct SocrataCameraCatalogue: Sendable {
    private init() {}

    /// Parse a Socrata JSON array into `PublicFeedSource` values.
    ///
    /// - Parameters:
    ///   - data: JSON data containing an array of camera records.
    ///   - datasetURL: The URL of the Socrata dataset (used for citations and stable IDs).
    ///   - refreshInterval: Polling interval in seconds (must be ≥ 1 second).
    ///   - retrievedAt: When the dataset was retrieved (for citation).
    /// - Returns: An `SocrataImportResult` containing the imported sources and skip information.
    /// - Throws: If the JSON is malformed or not an array.
    public static func sources(
        fromJSON data: Data,
        datasetURL: URL,
        refreshInterval: TimeInterval = 60,
        retrievedAt: Date = Date()
    ) throws -> SocrataImportResult {
        let json = try JSONSerialization.jsonObject(with: data)
        guard let records = json as? [[String: Any]] else {
            throw ImportError.malformedJSON("Root element is not an array of objects")
        }

        var sources: [PublicFeedSource] = []
        var skipReasons: [SkipReason] = []
        var seenCameraIDs = Set<String>()

        let citation = SourceCitation(
            sourceType: .openDataPortal,
            url: datasetURL,
            retrievedAt: retrievedAt
        )

        let terms = FeedTerms(
            licenseClass: .publicDomain,
            termsURL: nil,
            termsReadOn: nil,
            attribution: "City of Austin",
            automatedUseAllowed: false
        )

        for record in records {
            guard let cameraID = record["camera_id"] as? String else {
                continue
            }

            if seenCameraIDs.contains(cameraID) {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .duplicateCameraID))
                continue
            }

            guard let status = record["camera_status"] as? String, status == "TURNED_ON" else {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .notTurnedOn))
                continue
            }

            guard let screenshotAddress = record["screenshot_address"] as? String,
                  !screenshotAddress.isEmpty else {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .missingImageURL))
                continue
            }

            guard let imageURL = URL(string: screenshotAddress) else {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .invalidImageURL))
                continue
            }

            guard imageURL.scheme?.lowercased() == "https" else {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .nonHTTPSURL))
                continue
            }

            guard let host = imageURL.host, !host.isEmpty else {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .invalidImageURL))
                continue
            }

            guard let location = record["location"] as? [String: Any],
                  let coordinates = location["coordinates"] as? [Double],
                  coordinates.count == 2 else {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .missingCoordinates))
                continue
            }

            let longitude = coordinates[0]
            let latitude = coordinates[1]

            if longitude == 0 && latitude == 0 {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .zeroCoordinates))
                continue
            }

            guard longitude >= -180 && longitude <= 180 && latitude >= -90 && latitude <= 90 else {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .invalidCoordinates))
                continue
            }

            let geohash6 = Geohash.encode(latitude: latitude, longitude: longitude, precision: 6)

            let trimmedName = (record["location_name"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)

            let stableID = stableUUID(datasetURL: datasetURL, cameraID: cameraID)

            do {
                let source = try PublicFeedSource(
                    id: stableID,
                    name: trimmedName,
                    url: imageURL,
                    kind: .snapshotJPEG,
                    refreshInterval: refreshInterval,
                    geohash6: geohash6,
                    citation: citation,
                    termsNote: "",
                    terms: terms,
                    nativeLongSide: nil,
                    locationConfidence: .surveyed
                )
                sources.append(source)
                seenCameraIDs.insert(cameraID)
            } catch PublicFeedSource.CreationError.refreshIntervalTooAggressive {
                skipReasons.append(SkipReason(cameraID: cameraID, reason: .refreshIntervalTooAggressive))
            } catch {
                throw error
            }
        }

        return SocrataImportResult(
            sources: sources,
            skippedCount: skipReasons.count,
            skipReasons: skipReasons
        )
    }

    /// Derive a stable UUID from the dataset URL and camera ID using SHA-256.
    private static func stableUUID(datasetURL: URL, cameraID: String) -> UUID {
        let input = "\(datasetURL.absoluteString)|\(cameraID)"
        let hash = SHA256.hash(data: Data(input.utf8))
        let bytes = Array(hash.prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    private enum ImportError: Error, Equatable {
        case malformedJSON(String)
    }
}