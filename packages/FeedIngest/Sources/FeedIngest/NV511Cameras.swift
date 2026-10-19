import Foundation
import PlateKit

/// Nevada's published IBI camera schema includes multiple views with separate
/// snapshot and HLS URLs. Credentials authorise only the catalogue request;
/// imported media hosts always await their own human terms review.
public enum NV511Cameras {
    public static let apiDocs = URL(string: "https://www.nvroads.com/help/endpoint/cameras")!
    public static let endpoint = URL(string: "https://www.nvroads.com/api/v2/get/cameras")!

    public static func sources(fromJSON data: Data, key: String,
                               endpointURL: URL = endpoint,
                               refreshInterval: TimeInterval = 300,
                               retrievedAt: Date = Date()) throws -> SocrataImportResult {
        try IBI511.sources(fromJSON: data, key: key,
                           config: .init(state: "NV", label: "NV511", attribution: "Nevada 511 / NDOT"),
                           endpointURL: endpointURL, refreshInterval: refreshInterval, retrievedAt: retrievedAt)
    }
}
