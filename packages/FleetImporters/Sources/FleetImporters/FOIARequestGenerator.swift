import Foundation

/// Drafts a public-records request about an agency's *fleet* (M3, FOIA
/// generator). It produces text only — nothing is sent anywhere. The user
/// reviews, personalizes, and files it through the agency's own portal or
/// through MuckRock.
///
/// Guardrails (docs/LEGAL-ETHICS.md):
/// - Asks only about taxpayer-funded vehicles and fleet-level policy. It never
///   asks for officer or employee names, home addresses, or personal
///   identifiers, and it never asks for DMV or driver records.
/// - The requester's name and contact are placeholders the user fills in.
///   The generator never reads or stores the user's identity.
/// - Unit numbers are echoed only when the caller supplies them from public
///   observations; they are validated and de-duplicated here.
public struct FOIARequestGenerator: Sendable {

    /// The agency a request is addressed to.
    public struct Target: Sendable, Equatable {
        public var agencyName: String
        /// Public-records office or portal, if known. Shown as guidance only.
        public var recordsOfficeURL: URL?
        public var stateName: String?

        public init(agencyName: String, recordsOfficeURL: URL? = nil, stateName: String? = nil) {
            self.agencyName = agencyName
            self.recordsOfficeURL = recordsOfficeURL
            self.stateName = stateName
        }
    }

    /// Which categories of record to request. All default on except the
    /// vendor contract, which many agencies answer in a separate request.
    public struct Scope: Sendable, Equatable {
        public var fleetInventory: Bool
        public var unitVehicleLinks: Bool
        public var alprPolicy: Bool
        public var alprRetention: Bool
        public var alprVendorContracts: Bool

        public init(fleetInventory: Bool = true,
                    unitVehicleLinks: Bool = true,
                    alprPolicy: Bool = true,
                    alprRetention: Bool = true,
                    alprVendorContracts: Bool = false) {
            self.fleetInventory = fleetInventory
            self.unitVehicleLinks = unitVehicleLinks
            self.alprPolicy = alprPolicy
            self.alprRetention = alprRetention
            self.alprVendorContracts = alprVendorContracts
        }
    }

    public struct Draft: Sendable, Equatable {
        public var subject: String
        public var body: String
        /// Unit numbers actually included after validation.
        public var includedUnits: [String]
        /// Unit numbers rejected, with reasons, so the UI can explain them.
        public var rejectedUnits: [String]
    }

    public init() {}

    public func draft(target: Target,
                      units: [String] = [],
                      scope: Scope = Scope(),
                      requestDate: Date = Date(),
                      requesterPlaceholder: String = "[Your name]") -> Draft {
        let (accepted, rejected) = Self.validateUnits(units)
        let subject = "Public records request: \(target.agencyName) fleet inventory and ALPR records"

        var items: [String] = []
        var n = 0
        func add(_ text: String) {
            n += 1
            items.append("\(n). \(text)")
        }

        if scope.fleetInventory {
            add("A list of all motor vehicles owned, leased, or operated by \(target.agencyName), with for each vehicle: unit or asset number, make, model, model year, vehicle category, and the registration plate number if the agency's records hold it.")
        }
        if scope.unitVehicleLinks {
            if accepted.isEmpty {
                add("Records that link each fleet unit or asset number to the vehicle it identifies (for example, an asset register or a unit-to-VIN/plate table). Please do not include names of employees.")
            } else {
                let list = accepted.joined(separator: ", ")
                add("Records that link the following unit or asset numbers to the vehicle each identifies: \(list). Please do not include names of employees.")
            }
        }
        if scope.alprPolicy {
            add("The current written policy, procedure, or general orders governing the use of automated license plate reader (ALPR) systems by \(target.agencyName), including any amendments in effect since January 1, 2020.")
        }
        if scope.alprRetention {
            add("The retention schedule(s) and deletion logs for ALPR detection data collected by \(target.agencyName), and the number of records deleted under each schedule in the last 12 months.")
        }
        if scope.alprVendorContracts {
            add("Contracts, purchase orders, and data-sharing agreements with any vendor that provides ALPR hardware, software, or hosted data storage to \(target.agencyName).")
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let dateText = formatter.string(from: requestDate)
        let stateLine = target.stateName.map { " (\($0))" } ?? ""
        let officeLine: String
        if let url = target.recordsOfficeURL {
            officeLine = "If your office requires this request to be filed through its portal, please treat this letter as the request filed there: \(url.absoluteString)"
        } else {
            officeLine = "Please direct this request to your public records office."
        }

        let body = """
        To the Public Records Officer, \(target.agencyName)\(stateLine):

        Under the public records law that applies to you, I request copies of the following records. These records concern vehicles and equipment paid for with public funds and the agency's public-safety technology policies, not any private individual.

        \(items.joined(separator: "\n\n"))

        Format: electronic records in their native format are preferred (CSV, XLSX, or PDF with searchable text). If any part is withheld, please identify the exemption you rely on and release the remaining non-exempt portions. If you estimate fees above $25, please contact me before proceeding.

        \(officeLine)

        Date of request: \(dateText)

        Sincerely,
        \(requesterPlaceholder)
        [Mailing address or email for the response]
        """

        return Draft(subject: subject, body: body,
                     includedUnits: accepted, rejectedUnits: rejected)
    }

    // MARK: - Unit validation

    /// A unit identifier is 1–12 characters of letters, digits, hyphen, or
    /// slash. Anything else (names, addresses, long free text, plates with
    /// spaces) is rejected so the letter cannot carry personal information.
    static func validateUnits(_ units: [String]) -> (accepted: [String], rejected: [String]) {
        var seen = Set<String>()
        var accepted: [String] = []
        var rejected: [String] = []
        for raw in units {
            let trimmed = raw.trimmingCharacters(in: .whitespaces).uppercased()
            guard !trimmed.isEmpty else { continue }
            guard isUnitIdentifier(trimmed) else {
                rejected.append(raw)
                continue
            }
            if seen.insert(trimmed).inserted {
                accepted.append(trimmed)
            }
        }
        return (accepted, rejected)
    }

    static func isUnitIdentifier(_ s: String) -> Bool {
        guard (1...12).contains(s.count) else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            (scalar.value >= 0x30 && scalar.value <= 0x39)   // 0-9
                || (scalar.value >= 0x41 && scalar.value <= 0x5A) // A-Z
                || scalar == "-" || scalar == "/"
        }
    }
}
