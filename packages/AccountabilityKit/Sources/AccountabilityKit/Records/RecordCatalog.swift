import Foundation
import PlateKit

/// A published list of accountability records that can be imported with one click: today, officer-certification actions
/// that a state standards body publishes as open data. (No prosecutor publishes a Brady/Giglio list as a download that we
/// could find — those arrive as PDFs or records-request releases and go through the CSV importer.)
///
/// Every row becomes a *pending* `RecordCandidate` with the source's own words; nothing is accepted or linked to anyone.
public struct RecordSource: Sendable, Identifiable, Hashable, Codable {
    public var id: String
    public var title: String
    public var kind: IncidentRecord.Kind
    public var releasedBy: String
    public var domain: String
    public var datasetID: String
    /// SoQL `$where` limiting the import (e.g. only revocations).
    public var filter: String
    public var firstNameField: String?
    public var lastNameField: String
    public var agencyField: String?
    public var referenceField: String
    public var statusField: String
    public var dateField: String?
    /// Extra columns copied verbatim into the excerpt, as `label: value`.
    public var excerptFields: [RosterSource.PayField]
    /// Column holding a per-record document link (`{url: …}` object or plain string), used as the citation URL when present.
    public var documentLinkField: String?
    public var note: String

    public var datasetPage: URL { URL(string: "https://\(domain)/d/\(datasetID)")! }
    var requestedFields: [String] {
        ([firstNameField, lastNameField, agencyField, referenceField, statusField, dateField, documentLinkField].compactMap { $0 }
            + excerptFields.map(\.field))
    }
}

public enum RecordCatalog {
    public static let all: [RecordSource] = [
        .init(id: "wa-cjtc-revocations", title: "Washington — officer certification revocations (CJTC)",
              kind: .decertification, releasedBy: "Washington State Criminal Justice Training Commission",
              domain: "data.wa.gov", datasetID: "r5ki-dmfz",
              filter: "starts_with(case_determination, 'Revocation')",
              firstNameField: "officer_first_name", lastNameField: "officer_name", agencyField: "employer",
              referenceField: "case", statusField: "case_determination", dateField: "final_order",
              excerptFields: [.init("Reason opened", "reason_for_opening_case"), .init("Conduct investigated", "conduct_investigated"),
                              .init("Certification", "certification_type")],
              documentLinkField: "documents_link",
              note: "Final revocations, surrenders and hearing outcomes; ~470 cases since 2002, with the final order linked."),
    ]

    public static func source(id: String) -> RecordSource? { all.first { $0.id == id } }
}

public struct RecordSourceFetcher: Sendable {
    public static let pageSize = 2000
    public static let maxRows = 50_000
    public enum FetchError: Error, Equatable { case http(Int), decoding, tooLarge }

    private let fetcher: HTTPFetching
    private let pause: @Sendable () async -> Void

    public init(fetcher: HTTPFetching = URLSessionFetcher(),
                pause: @escaping @Sendable () async -> Void = { try? await Task.sleep(nanoseconds: 500_000_000) }) {
        self.fetcher = fetcher; self.pause = pause
    }

    func request(_ source: RecordSource, offset: Int) -> URLRequest {
        var comps = URLComponents()
        comps.scheme = "https"; comps.host = source.domain; comps.path = "/resource/\(source.datasetID).json"
        comps.queryItems = [URLQueryItem(name: "$select", value: source.requestedFields.joined(separator: ",")),
                            URLQueryItem(name: "$where", value: source.filter), URLQueryItem(name: "$order", value: ":id"),
                            URLQueryItem(name: "$limit", value: String(Self.pageSize)), URLQueryItem(name: "$offset", value: String(offset))]
        var req = URLRequest(url: comps.url!)
        req.setValue("PlateWatch records import (open-source accountability tool)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        return req
    }

    public func candidates(from source: RecordSource, now: Date = Date(),
                           progress: (@Sendable (Int) -> Void)? = nil) async throws -> [RecordCandidate] {
        var out: [RecordCandidate] = []
        var offset = 0
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = "yyyy-MM-dd"
        while true {
            let (data, status) = try await fetcher.fetch(request(source, offset: offset))
            guard status == 200 else { throw FetchError.http(status) }
            guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { throw FetchError.decoding }
            for row in rows {
                func text(_ f: String?) -> String? {
                    guard let f, let v = row[f] else { return nil }
                    let s = ((v as? String) ?? (v as? NSNumber)?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
                    return (s?.isEmpty ?? true) ? nil : s
                }
                guard let reference = text(source.referenceField) else { continue }
                let name = [text(source.firstNameField), text(source.lastNameField)].compactMap { $0 }.joined(separator: " ")
                var parts = [String]()
                if !name.isEmpty { parts.append("Officer: \(name)") }
                if let a = text(source.agencyField) { parts.append("Employer: \(a)") }
                if let s = text(source.statusField) { parts.append("Determination: \(s)") }
                for f in source.excerptFields { if let v = text(f.field) { parts.append("\(f.label): \(v)") } }
                let excerpt = parts.joined(separator: "; ")
                var link: URL?
                if let f = source.documentLinkField {
                    if let obj = row[f] as? [String: Any], let u = obj["url"] as? String { link = URL(string: u) }
                    else if let u = row[f] as? String { link = URL(string: u) }
                }
                let sourceType: SourceCitation.SourceType = source.kind == .bradyList ? .bradyList : .decertificationRegister
                out.append(RecordCandidate(
                    kind: source.kind, reference: "\(reference) (\(source.releasedBy))", status: text(source.statusField) ?? "",
                    subjectName: name.isEmpty ? nil : name, agencyName: text(source.agencyField), releasedBy: source.releasedBy,
                    filedOn: text(source.dateField).flatMap { df.date(from: String($0.prefix(10))) }, excerpt: excerpt,
                    citation: SourceCitation(sourceType: sourceType, url: link ?? source.datasetPage, retrievedAt: now,
                                             excerptHashSHA256: Hashing.sha256Hex("\(source.id)|\(reference)|\(excerpt)"))))
            }
            progress?(out.count)
            if out.count > Self.maxRows { throw FetchError.tooLarge }
            if rows.count < Self.pageSize { break }
            offset += Self.pageSize
            await pause()
        }
        return out
    }
}
