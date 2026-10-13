import Foundation

/// US state names ↔ USPS codes. Pure lookup data shared by identity inference.
public enum USStates {
    public static let all: [(code: String, name: String)] = [
        ("AL", "Alabama"), ("AK", "Alaska"), ("AZ", "Arizona"), ("AR", "Arkansas"), ("CA", "California"),
        ("CO", "Colorado"), ("CT", "Connecticut"), ("DE", "Delaware"), ("FL", "Florida"), ("GA", "Georgia"),
        ("HI", "Hawaii"), ("ID", "Idaho"), ("IL", "Illinois"), ("IN", "Indiana"), ("IA", "Iowa"),
        ("KS", "Kansas"), ("KY", "Kentucky"), ("LA", "Louisiana"), ("ME", "Maine"), ("MD", "Maryland"),
        ("MA", "Massachusetts"), ("MI", "Michigan"), ("MN", "Minnesota"), ("MS", "Mississippi"),
        ("MO", "Missouri"), ("MT", "Montana"), ("NE", "Nebraska"), ("NV", "Nevada"), ("NH", "New Hampshire"),
        ("NJ", "New Jersey"), ("NM", "New Mexico"), ("NY", "New York"), ("NC", "North Carolina"),
        ("ND", "North Dakota"), ("OH", "Ohio"), ("OK", "Oklahoma"), ("OR", "Oregon"), ("PA", "Pennsylvania"),
        ("RI", "Rhode Island"), ("SC", "South Carolina"), ("SD", "South Dakota"), ("TN", "Tennessee"),
        ("TX", "Texas"), ("UT", "Utah"), ("VT", "Vermont"), ("VA", "Virginia"), ("WA", "Washington"),
        ("WV", "West Virginia"), ("WI", "Wisconsin"), ("WY", "Wyoming"), ("DC", "District of Columbia"),
    ]

    private static let byName: [String: String] = Dictionary(
        uniqueKeysWithValues: all.map { ($0.name.uppercased().replacingOccurrences(of: " ", with: ""), $0.code) })
    private static let byCode: [String: String] = Dictionary(uniqueKeysWithValues: all.map { ($0.code, $0.name) })

    /// "Massachusetts" / "MASSACHUSETTS" / "New York" / "NEWYORK" → "MA" / "NY".
    public static func code(forName name: String) -> String? {
        byName[name.uppercased().filter { $0.isLetter }]
    }

    /// "MA" or "US-MA" → "Massachusetts".
    public static func name(forCode code: String) -> String? {
        byCode[code.uppercased().replacingOccurrences(of: "US-", with: "")]
    }

    /// Strips an ISO prefix: "US-MA" → "MA".
    public static func code(fromRegion region: String?) -> String? {
        guard let region else { return nil }
        let c = region.uppercased().replacingOccurrences(of: "US-", with: "")
        return byCode[c] != nil ? c : nil
    }
}
