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
        "STATE TROOPER", "HIGHWAY PATROL", "POLICE", "SHERIFF", "MARSHAL",
        "FIRE", "RESCUE", "PARAMEDIC", "AMBULANCE", "EMS",
        "PUBLIC WORKS", "TRANSIT", "METRO", "SANITATION", "PARK RANGER",
        "UNIFIED SCHOOL DISTRICT", "SCHOOL DISTRICT"
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

    public static func parse(_ observations: [SceneTextObservation]) -> FleetMarkings {
        var result = FleetMarkings()
        var longestAgencyLine: String?

        for obs in observations {
            let line = obs.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty else { continue }
            let upper = line.uppercased()

            // Service class: first service keyword found anywhere wins,
            // but a later, higher-priority service keyword replaces it.
            if let match = serviceKeywords.first(where: { upper.contains($0) }) {
                if let current = result.serviceClassText,
                   let ci = serviceKeywords.firstIndex(of: current),
                   let ni = serviceKeywords.firstIndex(of: match), ni < ci {
                    result.serviceClassText = match
                } else if result.serviceClassText == nil {
                    result.serviceClassText = match
                }
            }
            let isAgencyLine = agencyKeywords.contains(where: { upper.contains($0) })
            if result.serviceClassText != nil || isAgencyLine {
                result.hasFleetKeyword = true
            }

            // Agency guess: the longest ownership/service-bearing line
            // ("CITY OF AUSTIN POLICE" outranks "POLICE").
            if isAgencyLine || result.serviceClassText.map({ upper.contains($0) }) == true,
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
