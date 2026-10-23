import Foundation
import PlateKit

/// Utah's documented camera API (<https://udottraffic.utah.gov/developers/doc>, 10 calls / 60 s) uses the shared IBI
/// 511 schema. The key is stored in the Keychain slot `utah-api` and authorises only the catalogue request.
/// This complements, and does not replace, the keyless public-GIS import (`CameraCatalogueImporters.utahTraffic`).
public enum UDOTCameras {
    public static let apiDocs = URL(string: "https://udottraffic.utah.gov/help/endpoint/cameras")!
    public static let endpoint = URL(string: "https://www.udottraffic.utah.gov/api/v2/get/cameras")!

    public static func sources(fromJSON data: Data, key: String,
                               endpointURL: URL = endpoint,
                               refreshInterval: TimeInterval = 300,
                               retrievedAt: Date = Date()) throws -> SocrataImportResult {
        try IBI511.sources(fromJSON: data, key: key,
                           config: .init(state: "UT", label: "UDOT", attribution: "Utah Department of Transportation"),
                           endpointURL: endpointURL, refreshInterval: refreshInterval, retrievedAt: retrievedAt)
    }
}
