import Foundation
import PlateKit

/// A public open-data roster the Hub can import with one click: an agency's employee list published by the agency's own
/// government on a Socrata open-data portal. Each entry was probed live on 2026-10-15 (fields and filter values exist).
///
/// Only the name and job-title fields are requested (`$select`), so gender, ethnicity, age, pay and every other column
/// never leave the portal — that is the public-capacity boundary applied at the request, not after the fact.
public struct RosterSource: Sendable, Identifiable, Hashable, Codable {
    public enum NameFields: Sendable, Hashable, Codable {
        /// Separate first/last columns; shown as "FIRST LAST".
        case firstLast(first: String, last: String)
        /// One column holding the name as the portal prints it ("LAST, FIRST M").
        case single(String)
    }

    public var id: String
    public var title: String
    public var agencyName: String
    /// Best-effort `VehicleIdentity.agencyKey` for the agency (`US-<state>/<place>/<service>`), pre-filled for unit links.
    public var agencyKey: String
    public var state: String
    public var domain: String
    public var datasetID: String
    public var names: NameFields
    public var roleField: String
    /// SoQL `$where` selecting the agency's rows.
    public var filter: String
    /// When set, only rows with the newest value of this column are imported (a fiscal/pay year, a payroll snapshot date).
    public var latestBy: String?
    /// One line shown in the picker: what the list contains and anything to know.
    public var note: String

    public var datasetPage: URL { URL(string: "https://\(domain)/d/\(datasetID)")! }
    var requestedFields: [String] {
        switch names {
        case .firstLast(let f, let l): return [f, l, roleField]
        case .single(let n): return [n, roleField]
        }
    }
}

public enum RosterCatalog {
    public static let all: [RosterSource] = [
        .init(id: "nypd", title: "New York City — Police Department", agencyName: "New York City Police Department",
              agencyKey: "US-NY/new-york/police", state: "NY", domain: "data.cityofnewyork.us", datasetID: "k397-673e",
              names: .firstLast(first: "first_name", last: "last_name"), roleField: "title_description",
              filter: "agency_name='POLICE DEPARTMENT'", latestBy: "fiscal_year",
              note: "Citywide Payroll Data, latest fiscal year; ~55,000 rows (sworn and civilian). The portal is slow on this one: about 2 minutes."),
        .init(id: "chicago-pd", title: "Chicago — Police Department", agencyName: "Chicago Police Department",
              agencyKey: "US-IL/chicago/police", state: "IL", domain: "data.cityofchicago.org", datasetID: "xzkq-xp2w",
              names: .single("name"), roleField: "job_titles", filter: "department='CHICAGO POLICE DEPARTMENT'", latestBy: nil,
              note: "Current employee names and titles; ~12,000 rows."),
        .init(id: "lapd", title: "Los Angeles — Police (LAPD)", agencyName: "Los Angeles Police Department",
              agencyKey: "US-CA/los-angeles/police", state: "CA", domain: "controllerdata.lacity.org", datasetID: "g9h8-fvhu",
              names: .firstLast(first: "first_name", last: "last_name"), roleField: "job_title",
              filter: "fms_department_title='POLICE' AND job_status='ACTIVE'", latestBy: "pay_year",
              note: "City Employee Payroll, latest pay year, active only; ~12,000 rows."),
        .init(id: "seattle-pd", title: "Seattle — Police Department", agencyName: "Seattle Police Department",
              agencyKey: "US-WA/seattle/police", state: "WA", domain: "data.seattle.gov", datasetID: "2khk-5ukd",
              names: .firstLast(first: "first_name", last: "last_name"), roleField: "job_title",
              filter: "department='Seattle Police Department'", latestBy: nil, note: "City of Seattle wage data; ~1,650 rows."),
        .init(id: "cincinnati-pd", title: "Cincinnati — Police Department", agencyName: "Cincinnati Police Department",
              agencyKey: "US-OH/cincinnati/police", state: "OH", domain: "data.cincinnati-oh.gov", datasetID: "wmj4-ygbf",
              names: .single("name"), roleField: "jobtitle", filter: "deptname='CPD-Department of Police'", latestBy: nil,
              note: "City employees with salaries (name and title only imported); ~1,200 rows."),
        .init(id: "baton-rouge-pd", title: "Baton Rouge — Police Department", agencyName: "Baton Rouge Police Department",
              agencyKey: "US-LA/baton-rouge/police", state: "LA", domain: "data.brla.gov", datasetID: "bj3z-jksg",
              names: .firstLast(first: "first_name", last: "last_name"), roleField: "job_title",
              filter: "department_name='POLICE DEPARTMENT'", latestBy: nil, note: "City-Parish employees; ~1,200 rows."),
        .init(id: "nj-state-police", title: "New Jersey — State Police", agencyName: "New Jersey State Police",
              agencyKey: "US-NJ/state/state-police", state: "NJ", domain: "data.nj.gov", datasetID: "iqwc-r2w7",
              names: .single("full_name"), roleField: "master_title_desc",
              filter: "master_department_agency_desc='LAW AND PUBLIC SAFETY' AND master_section_desc like 'STATE POLICE%'",
              latestBy: "as_of_date", note: "YourMoney agency payroll, latest quarter; enlisted, recruits and civilians; ~10,000 rows."),
        .init(id: "vermont-dps", title: "Vermont — Department of Public Safety", agencyName: "Vermont Department of Public Safety",
              agencyKey: "US-VT/state/state-police", state: "VT", domain: "data.vermont.gov", datasetID: "jgqy-2smf",
              names: .single("name"), roleField: "job_title", filter: "department='Public Safety'", latestBy: nil,
              note: "State employee list; includes State Police troopers and other DPS staff; ~800 rows."),
    ]

    public static func source(id: String) -> RosterSource? { all.first { $0.id == id } }
}

/// One imported roster: names and titles exactly as the portal published them, plus the single citation they share.
public struct RosterSnapshot: Sendable, Codable, Equatable {
    public struct Entry: Sendable, Codable, Hashable {
        public var name: String
        public var role: String
        public init(name: String, role: String) { self.name = name; self.role = role }
    }
    public var sourceID: String
    public var importedAt: Date
    /// The `latestBy` value that was imported (e.g. "2025"), when the source has one.
    public var asOf: String?
    public var entries: [Entry]

    public init(sourceID: String, importedAt: Date, asOf: String?, entries: [Entry]) {
        self.sourceID = sourceID; self.importedAt = importedAt; self.asOf = asOf; self.entries = entries
    }

    /// The citation any profile made from this snapshot carries: the dataset page, the import time, and a hash that binds
    /// the entry to the source/as-of/name/role it came from.
    public func citation(for entry: Entry, source: RosterSource) -> SourceCitation {
        SourceCitation(sourceType: .openDataPortal, url: source.datasetPage, retrievedAt: importedAt,
                       excerptHashSHA256: Hashing.sha256Hex("\(source.id)|\(asOf ?? "")|\(entry.name)|\(entry.role)"))
    }
}

/// Fetches a `RosterSource` from its Socrata portal in polite pages. Anything that is not a clean 200 aborts the import.
public struct RosterFetcher: Sendable {
    public static let pageSize = 5000
    public static let maxRows = 120_000

    public enum FetchError: Error, Equatable { case http(Int), decoding, tooLarge }

    private let fetcher: HTTPFetching
    private let pause: @Sendable () async -> Void

    /// `pause` runs between pages (default half a second) so a 55,000-row list is ~11 gentle requests.
    public init(fetcher: HTTPFetching = URLSessionFetcher(),
                pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 500_000_000) }) {
        self.fetcher = fetcher; self.pause = pause
    }

    func request(_ source: RosterSource, select: String, whereClause: String, order: String? = nil,
                 limit: Int, offset: Int = 0) -> URLRequest {
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = source.domain; comps.path = "/resource/\(source.datasetID).json"
        var items = [URLQueryItem(name: "$select", value: select), URLQueryItem(name: "$where", value: whereClause),
                     URLQueryItem(name: "$limit", value: String(limit)), URLQueryItem(name: "$offset", value: String(offset))]
        if let order { items.append(URLQueryItem(name: "$order", value: order)) }
        comps.queryItems = items
        var req = URLRequest(url: comps.url!)
        req.setValue("PlateWatch roster import (open-source accountability tool)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    private func rows(_ request: URLRequest) async throws -> [[String: String]] {
        let (data, status) = try await fetcher.fetch(request)
        guard status == 200 else { throw FetchError.http(status) }
        guard let json = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { throw FetchError.decoding }
        return json.map { $0.compactMapValues { ($0 as? String) ?? ($0 as? NSNumber)?.stringValue } }
    }

    /// Imports the whole roster. `progress` receives the number of rows so far.
    public func fetch(_ source: RosterSource, now: Date = Date(),
                      progress: (@Sendable (Int) -> Void)? = nil) async throws -> RosterSnapshot {
        var whereClause = source.filter
        var asOf: String?
        if let latest = source.latestBy {
            let r = try await rows(request(source, select: "max(\(latest)) as latest", whereClause: source.filter, limit: 1))
            if let value = r.first?["latest"] {
                asOf = value
                whereClause += " AND \(latest)='\(value.replacingOccurrences(of: "'", with: "''"))'"
            }
        }
        var entries: [RosterSnapshot.Entry] = []
        var offset = 0
        let select = source.requestedFields.joined(separator: ",")
        while true {
            let page = try await rows(request(source, select: select, whereClause: whereClause, order: ":id",
                                              limit: Self.pageSize, offset: offset))
            for row in page {
                let name: String
                switch source.names {
                case .firstLast(let f, let l):
                    name = [row[f], row[l]].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }.joined(separator: " ")
                case .single(let n): name = row[n]?.trimmingCharacters(in: .whitespaces) ?? ""
                }
                guard !name.isEmpty else { continue }
                entries.append(.init(name: name, role: row[source.roleField]?.trimmingCharacters(in: .whitespaces) ?? ""))
            }
            progress?(entries.count)
            if entries.count > Self.maxRows { throw FetchError.tooLarge }
            if page.count < Self.pageSize { break }
            offset += Self.pageSize
            await pause()
        }
        return RosterSnapshot(sourceID: source.id, importedAt: now, asOf: asOf, entries: entries)
    }
}

public extension RecordsLedger {
    /// Makes a cited profile from a roster entry (reusing an existing one with the same name and citation hash).
    @discardableResult
    mutating func addProfile(from entry: RosterSnapshot.Entry, snapshot: RosterSnapshot, source: RosterSource) throws -> OfficialProfile {
        let citation = snapshot.citation(for: entry, source: source)
        if let existing = profiles.first(where: { $0.citations.contains { $0.excerptHashSHA256 == citation.excerptHashSHA256 } }) { return existing }
        return try addProfile(name: entry.name, role: entry.role, citation: citation)
    }
}
