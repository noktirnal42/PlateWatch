import Foundation

/// Small text-matching helpers shared by identity inference.
enum TextMatching {
    /// Uppercase ASCII letters separated by single spaces. Spaces, hyphens, periods and
    /// slashes separate words; apostrophes and digits are dropped ("St. Paul's" → "ST PAULS").
    static func key(_ raw: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in raw.uppercased() {
            if ch.isASCII && ch.isLetter {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            } else if ch == " " || ch == "-" || ch == "." || ch == "/" || ch == "," {
                pendingSpace = true
            }
        }
        return out
    }

    /// Edit distance ≤ 1 (one substitution, insertion or deletion).
    static func withinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
        if abs(a.count - b.count) > 1 { return false }
        var i = 0, j = 0, edits = 0
        while i < a.count && j < b.count {
            if a[i] == b[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if a.count > b.count { i += 1 } else if a.count < b.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (a.count - i) + (b.count - j) <= 1
    }
}
