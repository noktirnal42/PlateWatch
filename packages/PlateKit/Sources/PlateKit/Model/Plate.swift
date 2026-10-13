import Foundation

/// A normalized license plate reading.
///
/// Normalization rules (OpenALPR-compatible): uppercase, strip spaces, dashes,
/// dots and decorative separators; keep only A–Z and 0–9. Keep the raw OCR
/// string alongside for auditability.
public struct Plate: Sendable, Hashable, Codable {
    /// Normalized text, e.g. "ABC1234".
    public let text: String
    /// Raw text as read by OCR before normalization.
    public let rawText: String
    /// ISO 3166-2 region code where known, e.g. "US-CA".
    public let issuingRegion: String?
    /// ISO 3166-1 alpha-2, e.g. "US".
    public let country: String
    /// Recognized plate family/design, e.g. "US-CA-exempt", "US-GOV",
    /// "US-NY-standard". Set by the plate-design classifier when available.
    public let plateDesign: String?
    /// Recognition confidence 0…1 (multi-frame fused where available).
    public let confidence: Double
    /// Official-use words printed on the plate ("POLICE", "OFFICIAL"). Kept after the
    /// registration is extracted so the service can be attributed to the plate.
    public let officialWords: [String]

    public init(text raw: String,
                issuingRegion: String? = nil,
                country: String = "US",
                plateDesign: String? = nil,
                confidence: Double = 0,
                officialWords: [String] = []) {
        self.officialWords = officialWords
        self.rawText = raw
        self.text = Plate.normalize(raw)
        self.issuingRegion = issuingRegion
        self.country = country
        self.plateDesign = plateDesign
        self.confidence = min(1, max(0, confidence))
    }

    /// Uppercases and removes anything that is not A–Z0–9.
    public static func normalize(_ raw: String) -> String {
        raw.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
    }

    /// Vision often returns a plate line without the gap between the official word and the number:
    /// "POLICED756" for "POLICE D756". Re-insert it, but only for a token that *begins* with an
    /// official word and whose remainder contains a digit, so ordinary words are never split.
    static func separatingGluedOfficialWords(_ raw: String) -> String {
        raw.split(separator: " ", omittingEmptySubsequences: false).map { token -> String in
            let t = token.uppercased().filter { $0.isLetter || $0.isNumber }
            guard t.contains(where: \.isNumber) else { return String(token) }
            for word in officialPlateWords where !word.contains(" ") && t.hasPrefix(word) && t.count > word.count {
                let rest = String(t.dropFirst(word.count))
                if rest.contains(where: \.isNumber), rest.count <= 8 { return "\(word) \(rest)" }
            }
            return String(token)
        }.joined(separator: " ")
    }

    /// Official-use words present in a plate line ("POLICE D756 OFFICIAL" → ["POLICE", "OFFICIAL"]).
    public static func officialWords(in raw: String) -> [String] {
        let padded = " " + separatingGluedOfficialWords(raw).uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) } + " "
        return officialPlateWords.filter { padded.contains(" \($0) ") }
    }

    /// ISO 3166-2 region code for a US state name as printed on plate headers
    /// ("Massachusetts" → "US-MA"). Unknown names return nil. Jurisdiction
    /// from the plate is metadata logged with the sighting — never evidence
    /// of a fleet role on its own.
    public static func issuingRegion(forStateName stateName: String) -> String? {
        let codes = ["AL", "AK", "AZ", "AR", "CA", "CO", "CT", "DE", "FL", "GA", "HI",
                     "ID", "IL", "IN", "IA", "KS", "KY", "LA", "ME", "MD", "MA", "MI",
                     "MN", "MS", "MO", "MT", "NE", "NV", "NH", "NJ", "NM", "NY", "NC",
                     "ND", "OH", "OK", "OR", "PA", "RI", "SC", "SD", "TN", "TX", "UT",
                     "VT", "VA", "WA", "WV", "WI", "WY", "DC"]
        let names = ["ALABAMA", "ALASKA", "ARIZONA", "ARKANSAS", "CALIFORNIA", "COLORADO",
                     "CONNECTICUT", "DELAWARE", "FLORIDA", "GEORGIA", "HAWAII", "IDAHO",
                     "ILLINOIS", "INDIANA", "IOWA", "KANSAS", "KENTUCKY", "LOUISIANA",
                     "MAINE", "MARYLAND", "MASSACHUSETTS", "MICHIGAN", "MINNESOTA",
                     "MISSISSIPPI", "MISSOURI", "MONTANA", "NEBRASKA", "NEVADA",
                     "NEW HAMPSHIRE", "NEW JERSEY", "NEW MEXICO", "NEW YORK",
                     "NORTH CAROLINA", "NORTH DAKOTA", "OHIO", "OKLAHOMA", "OREGON",
                     "PENNSYLVANIA", "RHODE ISLAND", "SOUTH CAROLINA", "SOUTH DAKOTA",
                     "TENNESSEE", "TEXAS", "UTAH", "VERMONT", "VIRGINIA", "WASHINGTON",
                     "WEST VIRGINIA", "WISCONSIN", "WYOMING", "DISTRICT OF COLUMBIA"]
        // Single-token match first ("TEXAS"), then collapsed two-word names
        // ("NEW YORK" → "NEWYORK") for lines split across OCR tokens.
        let upper = stateName.uppercased()
        if let i = names.firstIndex(of: upper) { return "US-\(codes[i])" }
        if let i = names.firstIndex(of: upper.replacingOccurrences(of: " ", with: "")) {
            return "US-\(codes[i])"
        }
        return nil
    }

    /// Could this normalized text plausibly be a US license plate reading?
    /// Rejects what Vision text recognition finds on vehicles that is *not* a
    /// plate: words and slogans ("NEWYORK", "COMPANY7", "DRIVEU"), pure digit
    /// strings (fleet / asset IDs on USPS vans, unit numbers) and strings too
    /// short or long. A real plate is 5–8 characters, mixes letters **and**
    /// digits, and has no run of 5+ letters. Vanity all-letter plates are a
    /// known miss until the CoreML plate detector ships.
    public static func isPlausibleReading(_ normalized: String) -> Bool {
        guard (5...8).contains(normalized.count) else { return false }
        let hasDigit = normalized.contains(where: \.isNumber)
        let hasLetter = normalized.contains(where: \.isLetter)
        guard hasDigit, hasLetter else { return false }
        var run = 0
        for ch in normalized {
            run = ch.isLetter ? run + 1 : 0
            if run >= 5 { return false }
        }
        return true
    }

    /// Words printed on government plates: Massachusetts "POLICE D756 OFFICIAL",
    /// "US GOVT", "STATE OWNED"… Their presence is itself strong evidence of a
    /// government vehicle — private owners cannot register such a plate.
    static let officialPlateWords: [String] = [
        "POLICE", "OFFICIAL", "GOVERNMENT", "GOVT", "EXEMPT", "STATE OWNED", "MUNICIPAL", "SHERIFF",
    ]

    /// US state names as printed on plate headers ("Massachusetts" above the
    /// registration). Detected jurisdiction is logged on the plate — it is
    /// metadata about where the vehicle is registered, never evidence of a
    /// fleet role on its own.
    static let usaStateNames: Set<String> = [
        "ALABAMA", "ALASKA", "ARIZONA", "ARKANSAS", "CALIFORNIA", "COLORADO", "CONNECTICUT",
        "DELAWARE", "FLORIDA", "GEORGIA", "HAWAII", "IDAHO", "ILLINOIS", "INDIANA", "IOWA",
        "KANSAS", "KENTUCKY", "LOUISIANA", "MAINE", "MARYLAND", "MASSACHUSETTS", "MICHIGAN",
        "MINNESOTA", "MISSISSIPPI", "MISSOURI", "MONTANA", "NEBRASKA", "NEVADA", "NEW HAMPSHIRE",
        "NEW JERSEY", "NEW MEXICO", "NEW YORK", "NORTH CAROLINA", "NORTH DAKOTA", "OHIO",
        "OKLAHOMA", "OREGON", "PENNSYLVANIA", "RHODE ISLAND", "SOUTH CAROLINA", "SOUTH DAKOTA",
        "TENNESSEE", "TEXAS", "UTAH", "VERMONT", "VIRGINIA", "WASHINGTON", "WEST VIRGINIA",
        "WISCONSIN", "WYOMING", "DISTRICT OF COLUMBIA",
    ]

    /// If `raw` is an official/government plate line, returns the registration
    /// with the official words removed ("POLICE D756" → "D756"). Registrations on
    /// these plates are short (3–8 characters), so the usual 5-character floor
    /// does not apply — but at least one digit and one letter/digit run is required.
    /// A leading state name ("Massachusetts POLICE D756") is returned as
    /// `jurisdiction`, never as part of the registration.
    public static func officialRegistration(from raw: String,
                                            allowWordOnly: Bool = false) -> (registration: String, design: String, jurisdiction: String?)? {
        var upper = " " + separatingGluedOfficialWords(raw).uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) } + " "
        var matched: [String] = []
        for word in officialPlateWords where upper.contains(" \(word) ") {
            matched.append(word)
            upper = upper.replacingOccurrences(of: " \(word) ", with: " ")
        }
        guard !matched.isEmpty else { return nil }
        // Registration = what is left, minus a leading state name token
        // ("Massachusetts POLICE D756" → registration "D756", jurisdiction
        // "MASSACHUSETTS" for the caller to log as the issuing region).
        var jurisdiction: String?
        let leftover = upper.split(separator: " ").map(String.init)
            .filter { token in
                if jurisdiction == nil, Plate.usaStateNames.contains(token) {
                    jurisdiction = token
                    return false
                }
                return true
            }
            .joined()
        // Some states issue plates that read only the word ("POLICE" on Minnesota squad
        // cars). That is the registration, but only trustworthy inside a detected plate
        // rectangle — never for door lettering — so callers must opt in.
        if leftover.isEmpty, allowWordOnly {
            return (matched.joined(), "word-only-vanity", jurisdiction)
        }
        guard (3...8).contains(leftover.count), leftover.contains(where: \.isNumber) else { return nil }
        var run = 0
        for ch in leftover { run = ch.isLetter ? run + 1 : 0; if run >= 5 { return nil } }
        return (leftover, "government-official", jurisdiction)
    }

    /// (State names moved to `usaStateNames` — used for jurisdiction logging.)

    /// Government-exempt style hints from the normalized text/design.
    /// This never asserts a fleet identity on its own — it is one signal for
    /// `FleetClassifier`.
    public var exemptDesignHint: Bool {
        guard let design = plateDesign?.lowercased() else { return false }
        return design.contains("exempt") || design.contains("gov") || design.contains("municipal")
            || design.contains("official")
    }

    /// True when the plate itself carries an official-use word (POLICE, OFFICIAL…).
    public var isOfficialPlate: Bool { plateDesign?.lowercased().contains("official") == true }
}
