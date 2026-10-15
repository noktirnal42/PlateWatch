import Foundation
import PlateKit

/// What the operator's own device may show next to a fleet unit it has just recognised. Unit numbers repeat across
/// agencies, so a lookup needs the recognised agency's key and **fails closed without one**.
///
/// **Location firewall (docs/ACCOUNTABILITY-DATA.md):** the only inputs are a unit number and an agency. There is
/// deliberately no sighting, place, time or camera parameter, so nothing returned can carry — or be joined to — where or
/// when a person was seen, and nothing here is a presence alert. Only moderator-confirmed links and cited records appear;
/// inferred links never do.
public struct UnitRecordsIndex: Sendable {
    public struct Result: Sendable, Equatable {
        public var agencyRecords: [IncidentRecord]
        public var officials: [Official]
        public var isEmpty: Bool { agencyRecords.isEmpty && officials.isEmpty }
    }
    public struct Official: Sendable, Equatable {
        public var profile: OfficialProfile
        public var link: PersonLink
        public var records: [IncidentRecord]
    }

    private let links: [PersonLink]
    private let profiles: [OfficialProfile.ID: OfficialProfile]
    private let incidents: [IncidentRecord]

    public init(ledger: RecordsLedger) {
        self.links = ledger.links.filter(\.canPublish)
        self.profiles = Dictionary(ledger.profiles.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.incidents = ledger.incidents
    }

    public func records(forUnit unit: String, agencyKey: String?) -> Result {
        let wanted = Self.normalise(unit), agency = Self.normalise(agencyKey ?? "")
        guard !agency.isEmpty else { return Result(agencyRecords: [], officials: []) }
        let officials: [Official] = wanted.isEmpty ? [] : links.compactMap { link in
            guard Self.normalise(link.unitNumber) == wanted, Self.normalise(link.agencyKey ?? "") == agency,
                  let profile = profiles[link.officialID] else { return nil }
            return Official(profile: profile, link: link, records: incidents.filter { $0.subjectID == profile.id })
        }
        let agencyRecords = incidents.filter { $0.subjectID == nil && Self.normalise($0.agencyKey ?? "") == agency }
        return Result(agencyRecords: agencyRecords, officials: officials)
    }

    static func normalise(_ unit: String) -> String {
        unit.uppercased().filter { $0.isLetter || $0.isNumber }
    }
}
