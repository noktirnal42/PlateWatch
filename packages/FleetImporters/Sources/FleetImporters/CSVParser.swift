import Foundation

/// Minimal RFC 4180 CSV parser: quoted fields, embedded commas/newlines,
/// doubled-quote escapes, CRLF and LF row endings. No dependencies — the
/// importer job must run anywhere Swift runs (GitHub Actions cron, a Mac
/// mini, an iOS device).
public struct CSVParser: Sendable {

    public init() {}

    /// Returns one array of fields per data row. A single-column row is
    /// legal; empty trailing rows are dropped.
    public func parse(_ text: String) -> [[String]] {
        // Swift joins CR+LF into a single grapheme cluster, so normalize
        // line endings up front instead of matching them per character.
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var rows: [[String]] = []
        var field = ""
        var row: [String] = []
        var inQuotes = false
        var fieldWasQuoted = false
        var iterator = normalized.makeIterator()
        var pending: Character?

        func endField() {
            row.append(fieldWasQuoted ? field : field.trimmingCharacters(in: .whitespaces))
            field = ""
            fieldWasQuoted = false
        }
        func endRow() {
            endField()
            // Skip fully empty unquoted rows (trailing newline etc.).
            if !(row.count == 1 && row[0].isEmpty) {
                rows.append(row)
            }
            row = []
        }

        while true {
            let ch: Character
            if let p = pending { ch = p; pending = nil }
            else if let next = iterator.next() { ch = next }
            else { break }

            if inQuotes {
                if ch == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" { field.append("\"") }
                        else { inQuotes = false; pending = next }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else if ch == "\"" {
                inQuotes = true
                fieldWasQuoted = true
            } else if ch == "," {
                endField()
            } else if ch == "\n" {
                endRow()
            } else {
                field.append(ch)
            }
        }
        if !field.isEmpty || !row.isEmpty || fieldWasQuoted {
            endRow()
        }
        return rows
    }
}
