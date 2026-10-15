import Foundation
import PlateKit

/// A public record an adapter extracted, **before** anyone has looked at it. Candidates are the only thing importers
/// produce: nothing becomes an `IncidentRecord` (and nothing is linked to a person) until the operator accepts it.
/// Text fields are verbatim from the source — allegation ≠ fact, so there is no summarising field at all.
public struct RecordCandidate: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var kind: IncidentRecord.Kind
    /// The publisher's own reference (docket number, register row, list entry).
    public var reference: String
    /// Status exactly as the source words it; empty when the source gives none.
    public var status: String
    /// The name as the source prints it. Never normalised, never matched on its own.
    public var subjectName: String?
    public var agencyName: String?
    /// The office that released/published the record (a prosecutor's office, a POST board, a court).
    public var releasedBy: String
    public var filedOn: Date?
    /// The source row/entry text, truncated to `maxExcerpt`; the citation hashes the same text.
    public var excerpt: String
    public var citation: SourceCitation
    public var review: Review

    public enum Review: String, Sendable, Codable { case pending, accepted, rejected }

    public static let maxExcerpt = 600

    public init(id: UUID = UUID(), kind: IncidentRecord.Kind, reference: String, status: String = "",
                subjectName: String? = nil, agencyName: String? = nil, releasedBy: String, filedOn: Date? = nil,
                excerpt: String, citation: SourceCitation, review: Review = .pending) {
        self.id = id
        self.kind = kind
        self.reference = reference
        self.status = status
        self.subjectName = subjectName
        self.agencyName = agencyName
        self.releasedBy = releasedBy
        self.filedOn = filedOn
        self.excerpt = String(excerpt.prefix(Self.maxExcerpt))
        self.citation = citation
        self.review = review
    }

    public enum AcceptError: Error, Equatable { case alreadyReviewed, communityCitationOnly }

    /// Accepts the candidate as a cited record. `subject` is an explicit human choice; this never infers it.
    public mutating func accept(subject: OfficialProfile.ID?, agencyID: UUID?) throws -> IncidentRecord {
        guard review == .pending else { throw AcceptError.alreadyReviewed }
        guard citation.sourceType != .communityVerified else { throw AcceptError.communityCitationOnly }
        let record = try IncidentRecord(kind: kind, reference: reference, status: status, subjectID: subject,
                                        agencyID: agencyID, citations: [citation])
        review = .accepted
        return record
    }

    public mutating func reject() { if review == .pending { review = .rejected } }
}

/// Suggests which profile a candidate might be about. **A name alone never confirms identity**: every suggestion has a
/// confidence below 1 and says why; the operator picks (or doesn't).
public enum PersonMatcher {
    public struct Suggestion: Sendable, Hashable {
        public var profile: OfficialProfile
        public var confidence: Double
        public var reasons: [String]
    }

    public static func suggest(for candidate: RecordCandidate, among profiles: [OfficialProfile],
                               agencyID: UUID? = nil, limit: Int = 5) -> [Suggestion] {
        guard let name = candidate.subjectName.map(normalise), !name.isEmpty else { return [] }
        let nameTokens = Set(name.split(separator: " ").map(String.init))
        var out: [Suggestion] = []
        for profile in profiles {
            let other = normalise(profile.name)
            let tokens = Set(other.split(separator: " ").map(String.init))
            var confidence = 0.0
            var reasons: [String] = []
            if other == name { confidence = 0.5; reasons.append("same name as published") }
            else if let last = name.split(separator: " ").last, let otherLast = other.split(separator: " ").last,
                    last == otherLast, !nameTokens.isDisjoint(with: tokens.subtracting([String(last)])) {
                confidence = 0.3; reasons.append("same surname and a shared given name")
            } else { continue }
            if let agencyID, profile.agencyID == agencyID { confidence += 0.2; reasons.append("same agency") }
            else if let a = candidate.agencyName?.lowercased(), !a.isEmpty, profile.agencyID != nil {
                // Agency names are not compared as strings: a name match without an agency link stays weak.
                reasons.append("agency not confirmed")
            }
            out.append(.init(profile: profile, confidence: min(confidence, 0.85), reasons: reasons))
        }
        return Array(out.sorted { $0.confidence > $1.confidence }.prefix(limit))
    }

    static func normalise(_ s: String) -> String {
        let folded = s.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let cleaned = folded.unicodeScalars.map { CharacterSet.letters.contains($0) || $0 == " " ? Character($0) : " " }
        return String(cleaned).split(separator: " ").joined(separator: " ")
    }
}

/// Everything the local records workspace persists. Candidates keep their verbatim excerpt after acceptance.
public struct RecordsLedger: Sendable, Codable, Equatable {
    public var candidates: [RecordCandidate]
    public var incidents: [IncidentRecord]
    public var profiles: [OfficialProfile]
    public var links: [PersonLink]

    public init(candidates: [RecordCandidate] = [], incidents: [IncidentRecord] = [],
                profiles: [OfficialProfile] = [], links: [PersonLink] = []) {
        self.candidates = candidates; self.incidents = incidents; self.profiles = profiles; self.links = links
    }

    /// Adds new candidates, skipping any whose (kind, reference, citation hash) is already present.
    @discardableResult
    public mutating func add(_ new: [RecordCandidate]) -> Int {
        var seen = Set(candidates.map { Self.key($0) })
        var added = 0
        for c in new where seen.insert(Self.key(c)).inserted { candidates.append(c); added += 1 }
        return added
    }

    private static func key(_ c: RecordCandidate) -> String { "\(c.kind.rawValue)|\(c.reference)|\(c.citation.excerptHashSHA256 ?? "")" }

    public var pending: [RecordCandidate] { candidates.filter { $0.review == .pending } }

    public mutating func accept(candidateID: RecordCandidate.ID, subject: OfficialProfile.ID?, agencyID: UUID?) throws {
        guard let i = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        incidents.append(try candidates[i].accept(subject: subject, agencyID: agencyID))
    }
}
