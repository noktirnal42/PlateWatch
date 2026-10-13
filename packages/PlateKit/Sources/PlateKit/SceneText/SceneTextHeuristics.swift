import Foundation

/// Structured fleet markings parsed from scene text on a vehicle
/// (door/hood/roof text): agency name, unit number, service class words.
public struct FleetMarkings: Sendable, Equatable {
    public var agencyText: String?
    public var unitNumber: String?
    public var serviceClassText: String?   // "POLICE", "FIRE", "PUBLIC WORKS"…
    public var hasFleetKeyword: Bool
    /// The agency line names an owner ("CITY OF X", "X COUNTY", "… DEPARTMENT",
    /// "STATE …", "U.S. …"), not just a service word. A strong signal.
    public var agencyIsOwnerQualified: Bool = false

    public init(agencyText: String? = nil, unitNumber: String? = nil,
                serviceClassText: String? = nil, hasFleetKeyword: Bool = false,
                agencyIsOwnerQualified: Bool = false) {
        self.agencyIsOwnerQualified = agencyIsOwnerQualified
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
        if keyword.contains(" ") { return containsFuzzyPhrase(upper, keyword) }
        guard keyword.count >= 5 else { return false }
        let target = Array(keyword)
        return upper.split(whereSeparator: { !$0.isLetter }).contains {
            $0.count >= 5 && withinOneEdit(Array($0), target)
        }
    }

    /// Words that say *who owns it* (as opposed to what kind of service it is).
    private static let ownerMarkers: [String] = [
        "CITY OF", "COUNTY", "STATE OF", "DEPARTMENT", "DEPT",
        "U.S.", "UNITED STATES", "METROPOLITAN", "MUNICIPAL", "TOWNSHIP", "VILLAGE OF",
        // A state name next to a service word ("WYOMING HIGHWAY PATROL").
        "ALABAMA", "ALASKA", "ARIZONA", "ARKANSAS", "CALIFORNIA", "COLORADO", "CONNECTICUT",
        "DELAWARE", "FLORIDA", "GEORGIA", "HAWAII", "IDAHO", "ILLINOIS", "INDIANA", "IOWA",
        "KANSAS", "KENTUCKY", "LOUISIANA", "MAINE", "MARYLAND", "MASSACHUSETTS", "MICHIGAN",
        "MINNESOTA", "MISSISSIPPI", "MISSOURI", "MONTANA", "NEBRASKA", "NEVADA", "NEW HAMPSHIRE",
        "NEW JERSEY", "NEW MEXICO", "NEW YORK", "NORTH CAROLINA", "NORTH DAKOTA", "OHIO",
        "OKLAHOMA", "OREGON", "PENNSYLVANIA", "RHODE ISLAND", "SOUTH CAROLINA", "SOUTH DAKOTA",
        "TENNESSEE", "TEXAS", "UTAH", "VERMONT", "VIRGINIA", "WASHINGTON", "WEST VIRGINIA",
        "WISCONSIN", "WYOMING",
    ]

    /// Two text boxes that sit next to each other or stacked (a wrapped line).
    private static func areAdjacent(_ a: NormalizedBox, _ b: NormalizedBox) -> Bool {
        let maxHeight = max(a.height, b.height)
        let verticalGap = max(a.y, b.y) - min(a.y + a.height, b.y + b.height)
        let horizontalGap = max(a.x, b.x) - min(a.x + a.width, b.x + b.width)
        let overlapsHorizontally = horizontalGap < maxHeight * 0.5
        let overlapsVertically = verticalGap < maxHeight * 0.5
        return (overlapsHorizontally && verticalGap < maxHeight * 2.0)
            || (overlapsVertically && horizontalGap < maxHeight * 2.5)
    }

    /// "LIGHWAY PATROL" for "HIGHWAY PATROL": every word of a multi-word keyword must match the
    /// next token exactly, or within one edit when the word is 5+ letters. At least one word must be
    /// an exact match, so two garbled words alone cannot form a keyword.
    private static func containsFuzzyPhrase(_ upper: String, _ keyword: String) -> Bool {
        let want = keyword.split(separator: " ").map(String.init)
        let have = upper.split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard have.count >= want.count else { return false }
        for start in 0...(have.count - want.count) {
            var exact = 0, ok = true
            for (i, w) in want.enumerated() {
                let h = have[start + i]
                if h == w { exact += 1 }
                else if !(w.count >= 5 && h.count >= 4 && TextMatching.withinOneEdit(Array(w), Array(h))) { ok = false; break }
            }
            if ok && exact >= 1 { return true }
        }
        return false
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

        // Multi-word names are often read as separate stacked lines
        // ("HIGHWAY" / "PATROL"): also try adjacent pairs.
        if result.serviceClassText == nil || result.serviceClassText?.contains(" ") == false {
            for (i, a) in observations.enumerated() {
                for b in observations[(i + 1)...] where Self.areAdjacent(a.boundingBox, b.boundingBox) {
                    for (x, y) in [(a, b), (b, a)] {
                        let joined = (x.text + " " + y.text).uppercased()
                        if let multi = serviceKeywords.first(where: { $0.contains(" ") && containsWord(joined, $0) }) {
                            result.serviceClassText = multi
                            result.hasFleetKeyword = true
                            if longestAgencyLine == nil || (longestAgencyLine?.count ?? 0) < joined.count {
                                longestAgencyLine = joined
                            }
                        }
                    }
                }
            }
        }

        result.agencyText = longestAgencyLine
        if let agency = longestAgencyLine?.uppercased(), result.serviceClassText != nil {
            result.agencyIsOwnerQualified = ownerMarkers.contains { containsWord(agency, $0) }
        }
        return result
    }
}
