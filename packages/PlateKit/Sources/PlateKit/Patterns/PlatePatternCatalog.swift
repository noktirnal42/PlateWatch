import Foundation

/// Regional plate-format validation patterns. Ported-in spirit from the
/// OpenALPR runtime pattern data (AGPL-3.0, same license as this project)
/// and simplified to readable regexes. A pattern match is *supporting
/// evidence* for a reading, never a gate.
///
/// Legend (OpenALPR convention):
///   # = digit, @ = letter, ? = letter-or-digit
/// We compile those to regex at init.
public struct PlatePattern: Sendable, Hashable {
    public let region: String          // "US-CA"
    public let name: String            // "standard", "exempt", "dealer"…
    public let regex: NSRegularExpression

    public init(region: String, name: String, pattern: String) {
        self.region = region
        self.name = name
        let body = pattern
            .replacingOccurrences(of: "#", with: "\\d")
            .replacingOccurrences(of: "@", with: "[A-Z]")
            .replacingOccurrences(of: "?", with: "[A-Z0-9]")
        self.regex = try! NSRegularExpression(pattern: "^\(body)$")
    }

    public func matches(_ normalizedText: String) -> Bool {
        let range = NSRange(normalizedText.startIndex..., in: normalizedText)
        return regex.firstMatch(in: normalizedText, range: range) != nil
    }
}

public enum PlatePatternCatalog {
    /// Starter set: a handful of high-value US formats. Community expands
    /// this in `Resources/PlatePatterns.json` over time.
    public static let builtin: [PlatePattern] = [
        .init(region: "US-CA", name: "standard",    pattern: "#@@@###"),
        .init(region: "US-CA", name: "legacy",      pattern: "@@@###"),
        .init(region: "US-CA", name: "exempt",      pattern: "1#####"),   // CA state-owned 'E' handled at design level
        .init(region: "US-TX", name: "standard",    pattern: "@@@####"),
        .init(region: "US-NY", name: "standard",    pattern: "@@@####"),
        .init(region: "US-FL", name: "standard",    pattern: "@@@#@#"),
        .init(region: "US",    name: "us-government", pattern: "@@#####"),
        .init(region: "US",    name: "generic",     pattern: "??????"),
        .init(region: "US",    name: "generic7",    pattern: "???????"),
    ]

    /// Scores a normalized reading against candidate regions. Returns
    /// best-first (region, patternName) pairs.
    public static func rank(_ text: String, regions: [String] = []) -> [(region: String, pattern: String)] {
        let pool = regions.isEmpty ? builtin : builtin.filter { regions.contains($0.region) }
        return pool.filter { $0.matches(text) }.map { ($0.region, $0.name) }
    }
}
