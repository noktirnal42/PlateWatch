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

    public init(text raw: String,
                issuingRegion: String? = nil,
                country: String = "US",
                plateDesign: String? = nil,
                confidence: Double = 0) {
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

    /// If `raw` is an official/government plate line, returns the registration
    /// with the official words removed ("POLICE D756" → "D756"). Registrations on
    /// these plates are short (3–8 characters), so the usual 5-character floor
    /// does not apply — but at least one digit and one letter/digit run is required.
    public static func officialRegistration(from raw: String) -> (registration: String, design: String)? {
        var upper = " " + raw.uppercased().map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) } + " "
        var matched: [String] = []
        for word in officialPlateWords where upper.contains(" \(word) ") {
            matched.append(word)
            upper = upper.replacingOccurrences(of: " \(word) ", with: " ")
        }
        guard !matched.isEmpty else { return nil }
        // Registration = what is left, minus a leading state name token.
        let leftover = upper.split(separator: " ").map(String.init)
            .filter { !stateNames.contains($0) }
            .joined()
        guard (3...8).contains(leftover.count), leftover.contains(where: \.isNumber) else { return nil }
        var run = 0
        for ch in leftover { run = ch.isLetter ? run + 1 : 0; if run >= 5 { return nil } }
        return (leftover, "government-official")
    }

    private static let stateNames: Set<String> = [
        "MASSACHUSETTS", "CALIFORNIA", "TEXAS", "FLORIDA", "NEWYORK", "OHIO", "GEORGIA", "MICHIGAN",
    ]

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
