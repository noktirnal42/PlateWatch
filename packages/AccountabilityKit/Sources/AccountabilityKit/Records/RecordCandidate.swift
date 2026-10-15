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
    public mutating func accept(subject: OfficialProfile.ID?, agencyID: UUID?, agencyKey: String? = nil) throws -> IncidentRecord {
        guard review == .pending else { throw AcceptError.alreadyReviewed }
        guard citation.sourceType != .communityVerified else { throw AcceptError.communityCitationOnly }
        let record = try IncidentRecord(kind: kind, reference: reference, status: status, subjectID: subject,
                                        agencyID: agencyID, agencyKey: agencyKey, citations: [citation])
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
    public var rosterCandidates: [RosterCandidate]

    public init(candidates: [RecordCandidate] = [], incidents: [IncidentRecord] = [],
                profiles: [OfficialProfile] = [], links: [PersonLink] = [], rosterCandidates: [RosterCandidate] = []) {
        self.candidates = candidates; self.incidents = incidents; self.profiles = profiles; self.links = links
        self.rosterCandidates = rosterCandidates
    }

    /// Tolerates ledgers saved before a field existed (they decode with the missing arrays empty).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        candidates = try c.decodeIfPresent([RecordCandidate].self, forKey: .candidates) ?? []
        incidents = try c.decodeIfPresent([IncidentRecord].self, forKey: .incidents) ?? []
        profiles = try c.decodeIfPresent([OfficialProfile].self, forKey: .profiles) ?? []
        links = try c.decodeIfPresent([PersonLink].self, forKey: .links) ?? []
        rosterCandidates = try c.decodeIfPresent([RosterCandidate].self, forKey: .rosterCandidates) ?? []
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

    public mutating func accept(candidateID: RecordCandidate.ID, subject: OfficialProfile.ID?, agencyID: UUID?, agencyKey: String? = nil) throws {
        guard let i = candidates.firstIndex(where: { $0.id == candidateID }) else { return }
        incidents.append(try candidates[i].accept(subject: subject, agencyID: agencyID, agencyKey: agencyKey))
    }
}

// MARK: - People: profiles, unit links, record attachment (all explicit human steps, all cited)

public extension RecordsLedger {
    enum PeopleError: Error, Equatable { case unknownProfile, unknownLink, unknownIncident, communityCitationOnly }

    /// Adds an official **in their public capacity**; the citation (e.g. the agency's published roster page) is mandatory.
    @discardableResult
    mutating func addProfile(name: String, role: String, citation: SourceCitation) throws -> OfficialProfile {
        guard citation.sourceType != .communityVerified else { throw PeopleError.communityCitationOnly }
        let profile = try OfficialProfile(name: name, role: role, citations: [citation])
        profiles.append(profile)
        return profile
    }

    /// Records a *suggested* unit↔person link: confidence below 1, never shown until confirmed.
    @discardableResult
    mutating func proposeLink(profileID: OfficialProfile.ID, unitNumber: String, agencyKey: String,
                              confidence: Double = 0.5, citation: SourceCitation) throws -> PersonLink {
        guard profiles.contains(where: { $0.id == profileID }) else { throw PeopleError.unknownProfile }
        let link = try PersonLink(officialID: profileID, unitNumber: unitNumber, agencyKey: agencyKey,
                                  confidence: min(confidence, 0.95), citations: [citation])
        links.append(link)
        return link
    }

    /// Confirms a link with an additional **external** citation (a roster, a FOIA release…). A community claim cannot.
    mutating func confirmLink(id: PersonLink.ID, citation: SourceCitation) throws {
        guard let i = links.firstIndex(where: { $0.id == id }) else { throw PeopleError.unknownLink }
        try links[i].moderatorConfirm(additionalCitation: citation)
    }

    /// Attaches an accepted record to a profile. The human chose the profile; nothing infers it.
    mutating func attach(incidentID: IncidentRecord.ID, to profileID: OfficialProfile.ID) throws {
        guard profiles.contains(where: { $0.id == profileID }) else { throw PeopleError.unknownProfile }
        guard let i = incidents.firstIndex(where: { $0.id == incidentID }) else { throw PeopleError.unknownIncident }
        incidents[i].subjectID = profileID
    }

    /// Removes a profile and everything that points at it (takedown / correction). Records detach, they are not deleted.
    mutating func removeProfile(id: OfficialProfile.ID) {
        profiles.removeAll { $0.id == id }
        links.removeAll { $0.officialID == id }
        for i in incidents.indices where incidents[i].subjectID == id { incidents[i].subjectID = nil }
    }
}


// MARK: - Working with accepted records

public extension RecordsLedger {
    /// Sets (or clears) the agency an accepted record is about. Agency-level records — a lawsuit against a city or sheriff's
    /// office, an audit — show next to that agency's recognised units in Review; the key is `VehicleIdentity.agencyKey`.
    mutating func setAgency(incidentID: IncidentRecord.ID, agencyKey: String?) throws {
        guard let i = incidents.firstIndex(where: { $0.id == incidentID }) else { throw PeopleError.unknownIncident }
        let key = agencyKey?.trimmingCharacters(in: .whitespaces)
        incidents[i].agencyKey = (key?.isEmpty ?? true) ? nil : key
    }

    /// Takes an accepted record out of the ledger and puts its source candidate back to pending, so a mistaken acceptance
    /// is undone rather than lost.
    mutating func unaccept(incidentID: IncidentRecord.ID) {
        guard let i = incidents.firstIndex(where: { $0.id == incidentID }) else { return }
        let record = incidents.remove(at: i)
        if let c = candidates.firstIndex(where: {
            $0.review == .accepted && $0.kind == record.kind && $0.reference == record.reference
                && $0.citation.excerptHashSHA256 == record.citations.first?.excerptHashSHA256 }) {
            candidates[c].review = .pending
        }
    }
}
