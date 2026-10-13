import Foundation
import PlateKit

/// Link between a public official and a fleet unit/vehicle. Auto-suggested
/// links are **inference** — labeled, confidence-carrying, and never
/// publishable until a moderator confirms them with their own citation
/// (docs/ACCOUNTABILITY-DATA.md).
public struct PersonLink: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var officialID: OfficialProfile.ID
    public var unitNumber: String
    public var vehicleID: Vehicle.ID?
    /// 0…1. Inferred links must stay below `1` — only a moderator-confirmed,
    /// cited link may claim 1.
    public var confidence: Double
    public private(set) var isModeratorConfirmed: Bool
    public var citations: [SourceCitation]

    public enum ValidationError: Error, Equatable {
        case missingCitation
        case confirmedLinkRequiresCitation
        case fullConfidenceRequiresConfirmation
    }

    public init(id: UUID = UUID(),
                officialID: OfficialProfile.ID,
                unitNumber: String,
                vehicleID: Vehicle.ID? = nil,
                confidence: Double,
                isModeratorConfirmed: Bool = false,
                citations: [SourceCitation]) throws {
        guard !citations.isEmpty else {
            throw ValidationError.missingCitation
        }
        if isModeratorConfirmed, citations.allSatisfy({ $0.sourceType == .communityVerified }) {
            // A confirmation that only cites "someone said so" is not a
            // confirmation of record — require an external source too.
            throw ValidationError.confirmedLinkRequiresCitation
        }
        // Certainty is earned by confirmation, not asserted by input: a
        // link claiming ≥ 1 without moderator confirmation is rejected
        // outright rather than silently clamped.
        if confidence >= 1, !isModeratorConfirmed {
            throw ValidationError.fullConfidenceRequiresConfirmation
        }
        let clamped = min(max(confidence, 0), 1)
        self.id = id
        self.officialID = officialID
        self.unitNumber = unitNumber
        self.vehicleID = vehicleID
        self.confidence = clamped
        self.isModeratorConfirmed = isModeratorConfirmed
        self.citations = citations
    }

    /// Moderator confirmation, which requires a citation to an external
    /// record (not merely a community claim). The only path to publishable.
    public mutating func moderatorConfirm(additionalCitation citation: SourceCitation) throws {
        guard citation.sourceType != .communityVerified else {
            throw ValidationError.confirmedLinkRequiresCitation
        }
        citations.append(citation)
        isModeratorConfirmed = true
        confidence = max(confidence, 1)
    }

    /// May this link appear in any published surface? Inferred links never
    /// auto-publish, regardless of confidence.
    public var canPublish: Bool { isModeratorConfirmed }
}
