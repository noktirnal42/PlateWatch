import Foundation

/// Structured fleet markings parsed from scene text on a vehicle
/// (door/hood/roof text): agency name, unit number, service class words.
public struct FleetMarkings: Sendable, Equatable {
    public var agencyText: String?
    public var unitNumber: String?
    public var serviceClassText: String?   // "POLICE", "FIRE", "PUBLIC WORKS"…
    public var hasFleetKeyword: Bool

    public init(agencyText: String? = nil, unitNumber: String? = nil,
                serviceClassText: String? = nil, hasFleetKeyword: Bool = false) {
        self.agencyText = agencyText
        self.unitNumber = unitNumber
        self.serviceClassText = serviceClassText
        self.hasFleetKeyword = hasFleetKeyword
    }
}

/// Deterministic fallback parser for fleet markings. Used when the
/// FoundationModels structured parser is unavailable (pre-iOS 26 devices,
/// non-Apple platforms) and as a sanity check on its output.
public enum SceneTextHeuristics {

    /// Service-class words (what kind of fleet it is). Earlier = higher
    /// priority when several appear.
    private static let serviceKeywords: [String] = [
        "STATE TROOPER", "HIGHWAY PATROL", "POLICE", "SHERIFF", "TROOPER", "MARSHAL",
        "FIRE", "RESCUE", "PARAMEDIC", "AMBULANCE", "EMS",
        "PUBLIC WORKS", "TRANSIT", "METRO", "SANITATION", "PARK RANGER",
        "POSTAL SERVICE", "USPS",
        "UNIFIED SCHOOL DISTRICT", "SCHOOL DISTRICT", "SCHOOL BUS"
    ]

    /// Ownership words (who runs it). Alone still flags a fleet vehicle.
    private static let agencyKeywords: [String] = [
        "DEPARTMENT OF", "CITY OF", "COUNTY OF", "STATE OF",
        "U.S. GOVERNMENT", "US GOVERNMENT",
        "OFFICIAL USE ONLY", "FOR OFFICIAL USE", "MUNICIPAL"
    ]

    private static let unitRegexes: [NSRegularExpression] = [
        // "UNIT 4421", "UNIT-4421", "U 4421"
        try! NSRegularExpression(pattern: "\\bUNIT[-\\s]?#?\\s*([0-9A-Z]{1,8})\\b"),
        // "CAR 12", "CRUISER 7", "ENGINE 42", "LADDER 3", "TRUCK 9"
        try! NSRegularExpression(pattern: "\\b(CAR|CRUISER|ENGINE|LADDER|TRUCK|SQUAD|BATTALION)[-\\s]?#?\\s*([0-9A-Z]{1,6})\\b"),
        // Bare roof number: 3–5 digit line on its own
        try! NSRegularExpression(pattern: "^([0-9]{3,5})$"),
    ]

    /// Edit distance ≤ 1 between two ASCII words (substitution, insert, delete).
    private static func withinOneEdit(_ a: [Character], _ b: [Character]) -> Bool {
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

    /// OCR on stylized lettering often misreads one glyph ("POLIGE",
    /// "SHERIFE"). Single-word keywords of 5+ letters tolerate one edit; short
    /// ones (FIRE, EMS) stay exact so "FIRM"/"EMS"-like words do not match.
    private static func containsFuzzyWord(_ upper: String, _ keyword: String) -> Bool {
        guard keyword.count >= 5, !keyword.contains(" ") else { return false }
        let target = Array(keyword)
        return upper.split(whereSeparator: { !$0.isLetter }).contains {
            $0.count >= 5 && withinOneEdit(Array($0), target)
        }
    }

    /// Whole-word match: "EMS" must not fire inside "SYSTEMS"/"ITEMS", nor
    /// "FIRE" inside "FIREFOX" — a false fleet flag breaks the fleet-only rule.
    private static func containsWord(_ upper: String, _ keyword: String) -> Bool {
        var searchRange = upper.startIndex..<upper.endIndex
        while let found = upper.range(of: keyword, range: searchRange) {
            let before = found.lowerBound == upper.startIndex
                || !upper[upper.index(before: found.lowerBound)].isLetter
            let after = found.upperBound == upper.endIndex
                || !upper[found.upperBound].isLetter
            if before && after { return true }
            searchRange = found.upperBound..<upper.endIndex
        }
        return false
    }

    public static func parse(_ observations: [SceneTextObservation]) -> FleetMarkings {
        var result = FleetMarkings()
        var longestAgencyLine: String?

        for obs in observations {
            let line = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()

            // Service class: first service keyword found anywhere wins,
            // but a later, higher-priority service keyword replaces it.
            if let match = serviceKeywords.first(where: { containsWord(upper, $0) || containsFuzzyWord(upper, $0) }) {
                if let current = result.serviceClassText,
                   let ci = serviceKeywords.firstIndex(of: current),
                   let ni = serviceKeywords.firstIndex(of: match), ni < ci {
                    result.serviceClassText = match
                } else if result.serviceClassText == nil {
                    result.serviceClassText = match
                }
            }
            let isAgencyLine = agencyKeywords.contains(where: { containsWord(upper, $0) })
            if result.serviceClassText != nil || isAgencyLine {
                result.hasFleetKeyword = true
            }

            // Agency guess: the longest ownership/service-bearing line
            // ("CITY OF AUSTIN POLICE" outranks "POLICE").
            if isAgencyLine || result.serviceClassText.map({ containsWord(upper, $0) || containsFuzzyWord(upper, $0) }) == true,
               line.count > (longestAgencyLine?.count ?? 0) {
                longestAgencyLine = line
            }

            if result.unitNumber == nil {
                for re in unitRegexes {
                    let range = NSRange(upper.startIndex..., in: upper)
                    if let m = re.firstMatch(in: upper, range: range),
                       m.numberOfRanges >= 2,
                       let r = Range(m.range(at: m.numberOfRanges - 1), in: upper) {
                        result.unitNumber = String(upper[r])
                        break
                    }
                }
            }
        }

        result.agencyText = longestAgencyLine
        return result
    }
}
