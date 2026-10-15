import Foundation
import PlateKit

/// One row of a published agency roster, **before** it becomes an `OfficialProfile`.
///
/// Only name, role and (optionally) the unit/vehicle number are read; every other column in the file — addresses, phone
/// numbers, birth dates, pay data — is ignored and never stored, not even in the excerpt. This is the public-capacity
/// boundary of docs/ACCOUNTABILITY-DATA.md enforced at the importer.
public struct RosterCandidate: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var name: String
    public var role: String
    public var unitNumber: String?
    public var agencyName: String
    public var agencyKey: String?
    public var releasedBy: String
    /// Mapped columns only, as `Name: … ; Role: … ; Unit: …`.
    public var excerpt: String
    public var citation: SourceCitation
    public var review: RecordCandidate.Review

    public init(id: UUID = UUID(), name: String, role: String, unitNumber: String?, agencyName: String, agencyKey: String?,
                releasedBy: String, excerpt: String, citation: SourceCitation, review: RecordCandidate.Review = .pending) {
        self.id = id; self.name = name; self.role = role; self.unitNumber = unitNumber; self.agencyName = agencyName
        self.agencyKey = agencyKey; self.releasedBy = releasedBy; self.excerpt = excerpt; self.citation = citation; self.review = review
    }
}

public struct RosterImporter: Sendable {
    public struct Source: Sendable {
        public var title: String
        public var agencyName: String
        /// Agency key as `VehicleIdentity.agencyKey` spells it; needed for any unit link to be shown later.
        public var agencyKey: String?
        public var releasedBy: String
        public var url: URL?
        /// `.agencyRoster` (the agency's own page), `.foiaRelease`, or `.openDataPortal`.
        public var sourceType: SourceCitation.SourceType
        public var retrievedAt: Date
        public init(title: String, agencyName: String, agencyKey: String? = nil, releasedBy: String, url: URL? = nil,
                    sourceType: SourceCitation.SourceType = .agencyRoster, retrievedAt: Date = Date()) {
            self.title = title; self.agencyName = agencyName; self.agencyKey = agencyKey; self.releasedBy = releasedBy
            self.url = url; self.sourceType = sourceType; self.retrievedAt = retrievedAt
        }
    }

    public struct Columns: Sendable {
        public var name: String
        public var role: String?
        public var unit: String?
        public init(name: String, role: String? = nil, unit: String? = nil) { self.name = name; self.role = role; self.unit = unit }
    }

    public enum ImportError: Error, Equatable { case unsupportedSourceType, missingColumn(String), empty }

    public init() {}

    public func candidates(fromCSV text: String, source: Source, columns: Columns) throws -> [RosterCandidate] {
        guard [.agencyRoster, .foiaRelease, .openDataPortal].contains(source.sourceType) else { throw ImportError.unsupportedSourceType }
        let rows = PublishedListImporter.parseCSV(text)
        guard let header = rows.first, rows.count > 1 else { throw ImportError.empty }
        let index = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces).lowercased(), $0) },
                               uniquingKeysWith: { a, _ in a })
        func column(_ name: String?) throws -> Int? {
            guard let name else { return nil }
            guard let i = index[name.lowercased()] else { throw ImportError.missingColumn(name) }
            return i
        }
        let nameCol = try column(columns.name)!, roleCol = try column(columns.role), unitCol = try column(columns.unit)

        var out: [RosterCandidate] = []
        for row in rows.dropFirst() {
            func cell(_ i: Int?) -> String? {
                guard let i, i < row.count else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            guard let name = cell(nameCol) else { continue }
            let role = cell(roleCol) ?? ""
            let unit = cell(unitCol)
            var parts = ["Name: \(name)"]
            if !role.isEmpty { parts.append("Role: \(role)") }
            if let unit { parts.append("Unit: \(unit)") }
            let excerpt = parts.joined(separator: "; ")
            out.append(RosterCandidate(
                name: name, role: role, unitNumber: unit, agencyName: source.agencyName, agencyKey: source.agencyKey,
                releasedBy: source.releasedBy, excerpt: excerpt,
                citation: SourceCitation(sourceType: source.sourceType, url: source.url, retrievedAt: source.retrievedAt,
                                         excerptHashSHA256: Hashing.sha256Hex("\(source.agencyName)|\(excerpt)"))))
        }
        return out
    }
}

public extension RecordsLedger {
    /// Adds roster rows as pending candidates, skipping any already present (same agency, name, unit and source text).
    @discardableResult
    mutating func addRoster(_ new: [RosterCandidate]) -> Int {
        var seen = Set(rosterCandidates.map { $0.citation.excerptHashSHA256 ?? "" })
        var added = 0
        for c in new where seen.insert(c.citation.excerptHashSHA256 ?? "").inserted { rosterCandidates.append(c); added += 1 }
        return added
    }

    /// Accepts a roster row: creates the cited profile and, when the row names a unit and the agency is known, a
    /// *proposed* link (inference, hidden until confirmed). An existing profile with the same name from the same source
    /// URL is reused rather than duplicated. Returns the profile.
    @discardableResult
    mutating func acceptRoster(candidateID: RosterCandidate.ID) throws -> OfficialProfile {
        guard let i = rosterCandidates.firstIndex(where: { $0.id == candidateID }) else { throw PeopleError.unknownProfile }
        let c = rosterCandidates[i]
        guard c.review == .pending else { throw RecordCandidate.AcceptError.alreadyReviewed }
        guard c.citation.sourceType != .communityVerified else { throw PeopleError.communityCitationOnly }

        let profile: OfficialProfile
        if let existing = profiles.first(where: {
            PersonMatcher.normalise($0.name) == PersonMatcher.normalise(c.name)
                && $0.citations.contains { $0.url != nil && $0.url == c.citation.url } }) {
            profile = existing
        } else {
            profile = try addProfile(name: c.name, role: c.role, citation: c.citation)
        }
        if let unit = c.unitNumber, let key = c.agencyKey, !key.isEmpty,
           !links.contains(where: { $0.officialID == profile.id && $0.unitNumber == unit && $0.agencyKey == key }) {
            try proposeLink(profileID: profile.id, unitNumber: unit, agencyKey: key, confidence: 0.5, citation: c.citation)
        }
        rosterCandidates[i].review = .accepted
        return profile
    }

    mutating func rejectRoster(candidateID: RosterCandidate.ID) {
        if let i = rosterCandidates.firstIndex(where: { $0.id == candidateID }), rosterCandidates[i].review == .pending {
            rosterCandidates[i].review = .rejected
        }
    }

    var pendingRoster: [RosterCandidate] { rosterCandidates.filter { $0.review == .pending } }
}
