import Foundation

/// Where an externally-sourced fact came from. Required on all enrichment.
public struct SourceCitation: Sendable, Codable, Hashable {
    public var sourceType: SourceType
    public var url: URL?
    public var retrievedAt: Date
    /// SHA-256 of the excerpt/record body, hex-encoded — binds the fact to
    /// the exact document content at retrieval time.
    public var excerptHashSHA256: String?
    /// ed25519 pubkey hash of the submitting device (not identity-bearing).
    public var submittedByDeviceHash: String?

    public enum SourceType: String, Sendable, Codable, CaseIterable {
        case agencyRoster, fleetRegistry, foiaRelease, auctionListing
        case officialPost, openDataPortal, nhtsaVpic, communityVerified
    }

    public init(sourceType: SourceType,
                url: URL? = nil,
                retrievedAt: Date = Date(),
                excerptHashSHA256: String? = nil,
                submittedByDeviceHash: String? = nil) {
        self.sourceType = sourceType
        self.url = url
        self.retrievedAt = retrievedAt
        self.excerptHashSHA256 = excerptHashSHA256
        self.submittedByDeviceHash = submittedByDeviceHash
    }
}
