import Foundation
import PlateKit

/// Imports a list that a public body has **already published** as CSV: a prosecutor's Brady/Giglio list, a state POST
/// board's decertification register, an agency's public roster of sustained findings. The user points it at a file or
/// a URL they have the right to use; the importer does not discover or crawl sources.
///
/// Every row becomes a pending `RecordCandidate` carrying the row's own words and a citation hashing the row text.
public struct PublishedListImporter: Sendable {
    public struct Source: Sendable {
        public var kind: IncidentRecord.Kind          // .bradyList or .decertification
        public var title: String                      // "Example County DA Brady list (2026)"
        public var releasedBy: String                 // the office that published it — named, never inferred
        public var url: URL?
        public var retrievedAt: Date
        public init(kind: IncidentRecord.Kind, title: String, releasedBy: String, url: URL? = nil, retrievedAt: Date = Date()) {
            self.kind = kind; self.title = title; self.releasedBy = releasedBy; self.url = url; self.retrievedAt = retrievedAt
        }
    }

    /// Which CSV header is which. Matching is case-insensitive; unknown headers are kept in the excerpt only.
    public struct Columns: Sendable {
        public var name: String
        public var agency: String?
        public var reference: String?
        public var status: String?
        public var date: String?
        public init(name: String, agency: String? = nil, reference: String? = nil, status: String? = nil, date: String? = nil) {
            self.name = name; self.agency = agency; self.reference = reference; self.status = status; self.date = date
        }
    }

    public enum ImportError: Error, Equatable { case unsupportedKind, missingColumn(String), empty }

    public init() {}

    public func candidates(fromCSV text: String, source: Source, columns: Columns,
                           dateFormat: String = "yyyy-MM-dd") throws -> [RecordCandidate] {
        guard [.bradyList, .decertification].contains(source.kind) else { throw ImportError.unsupportedKind }
        let rows = Self.parseCSV(text)
        guard let header = rows.first, rows.count > 1 else { throw ImportError.empty }
        let index = Dictionary(header.enumerated().map { ($1.trimmingCharacters(in: .whitespaces).lowercased(), $0) },
                               uniquingKeysWith: { a, _ in a })
        func column(_ name: String?) throws -> Int? {
            guard let name else { return nil }
            guard let i = index[name.lowercased()] else { throw ImportError.missingColumn(name) }
            return i
        }
        let nameCol = try column(columns.name)!
        let agencyCol = try column(columns.agency), refCol = try column(columns.reference)
        let statusCol = try column(columns.status), dateCol = try column(columns.date)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = dateFormat

        let sourceType: SourceCitation.SourceType = source.kind == .bradyList ? .bradyList : .decertificationRegister
        var out: [RecordCandidate] = []
        for (n, row) in rows.dropFirst().enumerated() where row.contains(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
            func cell(_ i: Int?) -> String? {
                guard let i, i < row.count else { return nil }
                let v = row[i].trimmingCharacters(in: .whitespacesAndNewlines)
                return v.isEmpty ? nil : v
            }
            let excerpt = zip(header, row).map { "\($0.trimmingCharacters(in: .whitespaces)): \($1.trimmingCharacters(in: .whitespaces))" }
                .joined(separator: "; ")
            out.append(RecordCandidate(
                kind: source.kind,
                reference: cell(refCol) ?? "\(source.title), row \(n + 1)",
                status: cell(statusCol) ?? "",
                subjectName: cell(nameCol),
                agencyName: cell(agencyCol),
                releasedBy: source.releasedBy,
                filedOn: cell(dateCol).flatMap(formatter.date(from:)),
                excerpt: excerpt,
                citation: SourceCitation(sourceType: sourceType, url: source.url, retrievedAt: source.retrievedAt,
                                         excerptHashSHA256: Hashing.sha256Hex(excerpt))))
        }
        return out
    }

    /// Minimal RFC 4180 parser: quoted fields, doubled quotes, CRLF/LF, embedded newlines inside quotes.
    static func parseCSV(_ text: String) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = ""
        var inQuotes = false
        var chars = text.makeIterator()
        var pending: Character? = nil
        func next() -> Character? { if let p = pending { pending = nil; return p }; return chars.next() }
        while let c = next() {
            if inQuotes {
                if c == "\"" {
                    if let d = next() { if d == "\"" { field.append("\"") } else { inQuotes = false; pending = d } } else { inQuotes = false }
                } else { field.append(c) }
            } else {
                switch c {
                case "\"": inQuotes = true
                case ",": row.append(field); field = ""
                case "\r\n", "\n", "\r": row.append(field); field = ""; rows.append(row); row = []
                default: field.append(c)
                }
            }
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows
    }
}
