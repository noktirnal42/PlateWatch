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

    /// Government-exempt style hints from the normalized text/design.
    /// This never asserts a fleet identity on its own — it is one signal for
    /// `FleetClassifier`.
    public var exemptDesignHint: Bool {
        guard let design = plateDesign?.lowercased() else { return false }
        return design.contains("exempt") || design.contains("gov") || design.contains("municipal")
    }
}
