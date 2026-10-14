import Foundation

/// What we know — and a human has confirmed — about a feed's terms. Public *viewing* is not a licence to analyse
/// or store (docs/FEED-SOURCES.md), so nothing is analysed until `automatedUseAllowed` is set by a person who
/// read the terms page recorded here.
public struct FeedTerms: Sendable, Hashable, Codable {
    public enum LicenseClass: String, Sendable, Codable {
        case publicDomain        // government statement or dedicated public domain
        case openLicence         // CC BY etc. — attribution required
        case keyed               // free API key / registration; terms accepted by the owner
        case permissioned        // written permission from the operator
        case askFirst            // operator has not granted anything — do not use
        case unknown
    }
    public var licenseClass: LicenseClass
    /// The terms page that was read, and when. Without these, no use is allowed.
    public var termsURL: URL?
    public var termsReadOn: Date?
    /// Credit line to carry with anything derived from the feed.
    public var attribution: String
    /// Set only by a human after reading `termsURL`. Defaults to false.
    public var automatedUseAllowed: Bool

    public init(licenseClass: LicenseClass = .unknown, termsURL: URL? = nil, termsReadOn: Date? = nil,
                attribution: String = "", automatedUseAllowed: Bool = false) {
        self.licenseClass = licenseClass
        self.termsURL = termsURL
        self.termsReadOn = termsReadOn
        self.attribution = attribution
        self.automatedUseAllowed = automatedUseAllowed
    }

    public static let unknown = FeedTerms()
}

/// How well a camera's position is known. Identity inference uses the location only to settle ambiguous place
/// names, so an unknown position means "no identity from this source" (aggregate counts only).
public enum LocationConfidence: String, Sendable, Codable {
    case surveyed       // coordinates published by the operator
    case approximate    // geohash-6 (~1 km) from a catalogue or curator
    case unknown
}

/// How much to ask of a frame, from its resolution. Measured on the eval corpus (docs/FEED-SOURCES.md §1):
/// fleet recall falls 63 % → 57 % (720p) → 35 % (480p) → 7 % (240p) as lettering and plates become unreadable.
public enum AnalysisTier: String, Sendable, Codable, Comparable {
    /// Enough pixels to read lettering and plates: run the thorough text path.
    case full
    /// Marginal: thorough path still helps, but identities need review.
    case reduced
    /// Too small to read text: appearance cues only, everything goes to the review queue, never auto-persisted
    /// as an identity.
    case appearanceOnly

    public static func tier(forLongSide pixels: Int) -> AnalysisTier {
        switch pixels {
        case 960...: return .full
        case 480..<960: return .reduced
        default: return .appearanceOnly
        }
    }

    /// Run the slower, more accurate text recognition path.
    public var thorough: Bool { self != .appearanceOnly }
    /// May an identity be asserted without review?
    public var identityMayBeConfirmed: Bool { self == .full }

    private var rank: Int { self == .full ? 0 : self == .reduced ? 1 : 2 }
    public static func < (a: AnalysisTier, b: AnalysisTier) -> Bool { a.rank < b.rank }
}
