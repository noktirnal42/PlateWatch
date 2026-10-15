import Foundation
import PlateKit

/// A public official or public employee **in their public capacity**
/// (docs/ACCOUNTABILITY-DATA.md, LEGAL-ETHICS Rule 6).
///
/// Construction is citation-gated: there is no way to build a profile without
/// at least one `SourceCitation`. Deliberately absent by type: home address,
/// personal contact data, biometric data — a profile that needs those is
/// outside this program's scope.
public struct OfficialProfile: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    /// Full name as published by the cited source (verbatim, not normalized).
    public var name: String
    /// Role as published ("Patrol Officer", "Chief", "Selectman"…).
    public var role: String
    /// Agency this person serves (reference to a PlateKit `Agency` record).
    public var agencyID: UUID?
    /// Public-capacity photo URL(s) with their citations. Never biometric
    /// templates — photos exist for human verification only.
    public var photos: [CitedPhoto]
    public var citations: [SourceCitation]
    public var status: Status

    public enum Status: String, Sendable, Codable {
        case active, retired, decertified, unknown
    }

    public struct CitedPhoto: Sendable, Hashable, Codable {
        public var url: URL
        public var citation: SourceCitation
        public init(url: URL, citation: SourceCitation) {
            self.url = url
            self.citation = citation
        }
    }

    public enum CreationError: Error, Equatable {
        case missingCitation
        case missingName
    }

    /// - Throws: `CreationError` when the public-record floor is not met.
    public init(id: UUID = UUID(),
                name: String,
                role: String = "",
                agencyID: UUID? = nil,
                photos: [CitedPhoto] = [],
                citations: [SourceCitation],
                status: Status = .unknown) throws {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CreationError.missingName
        }
        guard !citations.isEmpty else {
            throw CreationError.missingCitation
        }
        self.id = id
        self.name = name
        self.role = role
        self.agencyID = agencyID
        self.photos = photos
        self.citations = citations
        self.status = status
    }
}

/// A cited public record about an official or agency: Brady/Giglio list
/// entry, decertification register row, lawsuit docket, news report, or
/// official report. Content is stored **verbatim as released** — allegation
/// ≠ fact, and summaries must not go beyond the cited document.
public struct IncidentRecord: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var kind: Kind
    /// The publisher's own reference: docket number, register row ID, report
    /// number, or article headline. Verbatim.
    public var reference: String
    /// Case/report status as published ("pending", "settled", "terminated",
    /// "decertified"…). Verbatim from the source.
    public var status: String
    public var subjectID: OfficialProfile.ID?
    /// Agency the record is about (agency-level records, or the subject's agency). Reference to a PlateKit `Agency`.
    public var agencyID: UUID?
    /// The same agency as `VehicleIdentity.agencyKey` spells it; what agency-level records are looked up by.
    public var agencyKey: String?
    public var citations: [SourceCitation]

    public enum Kind: String, Sendable, Codable, CaseIterable {
        case bradyList, decertification, lawsuit, news, officialReport
    }

    public enum CreationError: Error, Equatable {
        case missingCitation
        case missingReference
    }

    public init(id: UUID = UUID(),
                kind: Kind,
                reference: String,
                status: String = "",
                subjectID: OfficialProfile.ID? = nil,
                agencyID: UUID? = nil,
                agencyKey: String? = nil,
                citations: [SourceCitation]) throws {
        guard !reference.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw CreationError.missingReference
        }
        guard !citations.isEmpty else {
            throw CreationError.missingCitation
        }
        self.id = id
        self.kind = kind
        self.reference = reference
        self.status = status
        self.subjectID = subjectID
        self.agencyID = agencyID
        self.agencyKey = agencyKey
        self.citations = citations
    }
}
