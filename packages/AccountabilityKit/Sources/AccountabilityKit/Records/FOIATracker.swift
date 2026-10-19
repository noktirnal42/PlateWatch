import Foundation
import PlateKit

/// Statutory response windows for public-records requests. **Convenience data, not legal advice:** every entry is
/// marked `verified: false` until someone reads the statute text (a 2026-10-15 desk check against secondary sources is in `checkedNote`), weekends are skipped but holidays are not, and
/// the requester can always override the due date (`FOIARequest.setDueDate`).
public enum FOIADeadlines {
    public struct Rule: Sendable, Hashable, Codable {
        public var days: Int
        public var businessDays: Bool
        /// What the window covers: some states only require an acknowledgement in the first period.
        public var covers: Covers
        public var citation: String
        /// True only once someone has read the statute text itself. `checkedNote` records weaker checks.
        public var verified: Bool
        /// What was checked and what to watch (2026-10-15 desk check against secondary sources; not statute text).
        public var checkedNote: String? = nil
        public enum Covers: String, Sendable, Codable { case response, acknowledgement }
    }

    /// Keyed by two-letter state code; "US" is the federal FOIA.
    public static let rules: [String: Rule] = [
        "US": .init(days: 20, businessDays: true, covers: .response, citation: "5 U.S.C. § 552(a)(6)(A)(i)", verified: false),
        "CA": .init(days: 10, businessDays: false, covers: .response, citation: "Cal. Gov. Code § 7922.535(a)", verified: false, checkedNote: "10 days to determine and give a production estimate, extendable up to 14 days in unusual circumstances. AB 1821 was chaptered 2026-09-30 (Ch. 899, Stats. 2026) and replaces these with 10 and 14 business days; the tracker switches for requests filed on or after 2027-01-01 (the default California effective date — confirm against the chaptered text)."),
        "TX": .init(days: 10, businessDays: true, covers: .acknowledgement, citation: "Tex. Gov't Code § 552.221(d)", verified: false, checkedNote: "Within 10 business days the agency must produce the records or certify in writing when it will; \"promptly\" (§ 552.221(a)) can be stricter."),
        "IL": .init(days: 5, businessDays: true, covers: .response, citation: "5 ILCS 140/3(d)", verified: false, checkedNote: "Confirmed in Attorney General binding opinions: comply or deny within 5 business days (one 5-business-day extension for listed reasons); silence is treated as a denial."),
        "MA": .init(days: 10, businessDays: true, covers: .response, citation: "M.G.L. c. 66, § 10(b)", verified: false, checkedNote: "10 business days from the records access officer's receipt; written extension reported up to 15 more business days."),
        "WA": .init(days: 5, businessDays: true, covers: .acknowledgement, citation: "RCW 42.56.520", verified: false, checkedNote: "Within 5 business days: provide the record, acknowledge with a time estimate, or deny. Day of receipt is not counted."),
        "NY": .init(days: 5, businessDays: true, covers: .acknowledgement, citation: "N.Y. Pub. Off. Law § 89(3)(a)", verified: false, checkedNote: "5 business days to make available, deny, or acknowledge with an approximate date. 2025 bills would add a 20-business-day period; not confirmed as law."),
        "VA": .init(days: 5, businessDays: true, covers: .response, citation: "Va. Code § 2.2-3704(B)", verified: true, checkedNote: "Statute text read at law.lis.virginia.gov on 2026-10-18: respond promptly and within five working days; if conditions prevent that, a written response within those five days gives the body seven more work days (60 work days for criminal investigative files under § 2.2-3706.1). The tracker uses the five-day window."),
        "CT": .init(days: 4, businessDays: true, covers: .response, citation: "Conn. Gen. Stat. § 1-206(a)", verified: false, checkedNote: "Denial must be in writing within 4 business days; failure is deemed a denial; appeal to the FOI Commission within 30 days."),
        "NH": .init(days: 5, businessDays: true, covers: .response, citation: "RSA 91-A:4, IV", verified: false, checkedNote: "Within 5 business days: make available, deny, or state the time reasonably needed (since 2020)."),
    ]

    /// Enacted changes that take effect later: the rule applies to requests filed on/after `effective`.
    public static let scheduledChanges: [String: (effective: Date, rule: Rule)] = [
        "CA": (Date(timeIntervalSince1970: 1_798_761_600), // 2027-01-01T00:00:00Z
               .init(days: 10, businessDays: true, covers: .response, citation: "Cal. Gov. Code § 7922.535(a) as amended by AB 1821 (Stats. 2026, ch. 899)", verified: false,
                     checkedNote: "10 business days to determine and notify; extension up to 14 business days. Chaptered 2026-09-30 per a secondary tracker — read the chaptered text.")),
    ]

    public static func rule(forState code: String?, asOf date: Date = Date()) -> Rule? {
        guard let code else { return nil }
        let key = code.uppercased()
        if let change = scheduledChanges[key], date >= change.effective { return change.rule }
        return rules[key]
    }

    /// The date `rule` falls due for a request submitted on `start`. Business days skip Saturday and Sunday only.
    public static func dueDate(from start: Date, rule: Rule, calendar: Calendar = .gregorianUTC) -> Date {
        guard rule.businessDays else { return calendar.date(byAdding: .day, value: rule.days, to: start) ?? start }
        var date = start, remaining = rule.days
        while remaining > 0 {
            date = calendar.date(byAdding: .day, value: 1, to: date) ?? date
            if !calendar.isDateInWeekend(date) { remaining -= 1 }
        }
        return date
    }
}

public extension Calendar {
    static var gregorianUTC: Calendar {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }
}

/// One public-records request, from draft to outcome. The released documents it produces are cited (`foiaRelease`) so
/// they can later back an `IncidentRecord` or `UnitAssignment`.
public struct FOIARequest: Sendable, Identifiable, Hashable, Codable {
    public let id: UUID
    public var agencyName: String
    /// Two-letter state code, or "US" for a federal agency.
    public var stateCode: String?
    public var subject: String
    public var body: String
    public private(set) var status: Status
    public private(set) var submittedOn: Date?
    public private(set) var dueOn: Date?
    public private(set) var dueDateIsOverride: Bool
    public private(set) var events: [Event]
    public private(set) var releases: [Release]

    public enum Status: String, Sendable, Codable, CaseIterable {
        case draft, submitted, acknowledged, inProgress, partiallyFulfilled, fulfilled, denied, appealed, closed
        public var isWaiting: Bool { [.submitted, .acknowledged, .inProgress].contains(self) }
    }

    public struct Event: Sendable, Hashable, Codable {
        public var date: Date
        public var text: String
    }

    /// A document the agency released. `citation.sourceType` is always `.foiaRelease`; the hash binds it to the bytes.
    public struct Release: Sendable, Hashable, Codable {
        public var receivedOn: Date
        public var description: String
        public var fileName: String?
        public var citation: SourceCitation
    }

    public enum TransitionError: Error, Equatable {
        case notYetSubmitted, alreadyClosed, appealNotApplicable, emptyDescription
    }

    public init(id: UUID = UUID(), agencyName: String, stateCode: String? = nil, subject: String, body: String) {
        self.id = id
        self.agencyName = agencyName
        self.stateCode = stateCode?.uppercased()
        self.subject = subject
        self.body = body
        self.status = .draft
        self.dueDateIsOverride = false
        self.events = []
        self.releases = []
    }

    /// Records that the requester filed it (the Hub never files anything itself). Sets the statutory due date when the
    /// state is known.
    public mutating func markSubmitted(on date: Date, calendar: Calendar = .gregorianUTC) {
        status = .submitted
        submittedOn = date
        if !dueDateIsOverride, let rule = FOIADeadlines.rule(forState: stateCode, asOf: date) {
            dueOn = FOIADeadlines.dueDate(from: date, rule: rule, calendar: calendar)
        }
        events.append(.init(date: date, text: "Submitted"))
    }

    public mutating func setDueDate(_ date: Date?) {
        dueOn = date
        dueDateIsOverride = date != nil
    }

    public mutating func transition(to new: Status, on date: Date, note: String = "") throws {
        guard status != .closed else { throw TransitionError.alreadyClosed }
        if new != .draft, new != .closed, submittedOn == nil { throw TransitionError.notYetSubmitted }
        if new == .appealed, ![.denied, .partiallyFulfilled].contains(status), !isOverdue(asOf: date) {
            throw TransitionError.appealNotApplicable
        }
        status = new
        events.append(.init(date: date, text: note.isEmpty ? "Status: \(new.rawValue)" : "Status: \(new.rawValue) — \(note)"))
    }

    public mutating func addNote(_ text: String, on date: Date) { events.append(.init(date: date, text: text)) }

    /// Attaches a released document. The citation hashes the file's bytes so the record can be re-verified later.
    public mutating func addRelease(description: String, fileName: String?, data: Data, receivedOn: Date,
                                    sourceURL: URL? = nil) throws {
        guard !description.trimmingCharacters(in: .whitespaces).isEmpty else { throw TransitionError.emptyDescription }
        let citation = SourceCitation(sourceType: .foiaRelease, url: sourceURL, retrievedAt: receivedOn,
                                      excerptHashSHA256: Hashing.sha256Hex(data))
        releases.append(.init(receivedOn: receivedOn, description: description, fileName: fileName, citation: citation))
        events.append(.init(date: receivedOn, text: "Received: \(description)"))
    }

    public func isOverdue(asOf now: Date) -> Bool {
        guard status.isWaiting, let dueOn else { return false }
        return now > dueOn
    }
}

public extension FOIARequest {
    /// A short appeal / follow-up letter for a denial or silence. Placeholders stay for the requester's details; the
    /// text asks for review and makes no legal claims beyond the request itself.
    func appealDraft(asOf now: Date, calendar: Calendar = .gregorianUTC) -> (subject: String, body: String) {
        let formatter = DateFormatter()
        formatter.calendar = calendar; formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .long; formatter.timeStyle = .none
        let filed = submittedOn.map(formatter.string(from:)) ?? "[date filed]"
        let reason: String
        switch status {
        case .denied: reason = "My request was denied. I ask for review of that decision."
        case .partiallyFulfilled: reason = "My request was only partly fulfilled. I ask for review of the records withheld."
        default: reason = "I have not received a determination within the response period that applies to my request"
            + (dueOn.map { " (due \(formatter.string(from: $0)))" } ?? "") + ". I ask that you respond or treat this as an appeal of the non-response."
        }
        let body = """
        To: \(agencyName) — Records Appeals / Records Officer

        Re: Public-records request filed \(filed)

        \(reason)

        Please provide: (1) the records requested, or (2) for anything withheld, the specific exemption relied on and the \
        portion of the record it covers, and (3) the name of the person to whom I may take a further appeal.

        Original request subject: \(subject)

        [Requester name]
        [Requester contact]
        """
        return ("Appeal / follow-up: \(subject)", body)
    }
}

/// The local list of requests, newest first. Persist with `JSONFileStore`.
public struct FOIATracker: Sendable, Codable, Equatable {
    public var requests: [FOIARequest]
    public init(requests: [FOIARequest] = []) { self.requests = requests }

    public mutating func upsert(_ request: FOIARequest) {
        if let i = requests.firstIndex(where: { $0.id == request.id }) { requests[i] = request } else { requests.insert(request, at: 0) }
    }
    public mutating func remove(id: FOIARequest.ID) { requests.removeAll { $0.id == id } }
    public func overdue(asOf now: Date) -> [FOIARequest] { requests.filter { $0.isOverdue(asOf: now) } }
}
