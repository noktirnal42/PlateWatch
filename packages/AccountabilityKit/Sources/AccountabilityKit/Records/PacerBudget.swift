import Foundation

/// PACER fee control. PACER waives fees for a user whose charges stay at or under a quarterly threshold (US$30 at the
/// time of writing — **confirm on pacer.uscourts.gov**, it is a setting here, not a constant of nature). Beyond that
/// every page costs money, so the guard works like this:
///
/// * Spending inside the free allowance is always allowed.
/// * Spending past it is allowed only up to `extraLimitUSD`, which defaults to **0** — so by default nothing is ever
///   billed. The user raises the limit explicitly (a dollar figure above the free allowance).
/// * Each call is checked with its *estimated* cost before it is made; the actual cost is recorded afterwards.
///
/// Charges are tracked per calendar quarter, matching PACER's billing quarters.
public struct PacerBudget: Sendable, Codable, Equatable {
    public var freeAllowanceUSD: Decimal
    public var extraLimitUSD: Decimal
    /// Cost per page of search results / docket sheets, and the per-document cap — PACER's published schedule.
    public var perPageUSD: Decimal
    public var perDocumentCapUSD: Decimal
    /// Spend per quarter key, e.g. "2026-Q4".
    public private(set) var spent: [String: Decimal]

    public init(freeAllowanceUSD: Decimal = 30, extraLimitUSD: Decimal = 0, perPageUSD: Decimal = Decimal(string: "0.10")!,
                perDocumentCapUSD: Decimal = 3, spent: [String: Decimal] = [:]) {
        self.freeAllowanceUSD = freeAllowanceUSD; self.extraLimitUSD = extraLimitUSD
        self.perPageUSD = perPageUSD; self.perDocumentCapUSD = perDocumentCapUSD; self.spent = spent
    }

    public enum Decision: Equatable, Sendable {
        case allowedFree
        case allowedPaid(billableUSD: Decimal)
        case denied(reason: String)
        public var isAllowed: Bool { if case .denied = self { return false }; return true }
    }

    public static func quarterKey(for date: Date, calendar: Calendar = .gregorianUTC) -> String {
        let c = calendar.dateComponents([.year, .month], from: date)
        return "\(c.year!)-Q\((c.month! - 1) / 3 + 1)"
    }

    public func spent(in date: Date) -> Decimal { spent[Self.quarterKey(for: date)] ?? 0 }
    public func remainingFree(on date: Date) -> Decimal { max(0, freeAllowanceUSD - spent(in: date)) }
    public func remainingExtra(on date: Date) -> Decimal { max(0, freeAllowanceUSD + extraLimitUSD - max(spent(in: date), freeAllowanceUSD)) }

    /// Estimated cost of fetching `pages` pages (a document is capped).
    public func estimate(pages: Int, isDocument: Bool = false) -> Decimal {
        let raw = perPageUSD * Decimal(max(0, pages))
        return isDocument ? min(raw, perDocumentCapUSD) : raw
    }

    public func check(estimatedCost: Decimal, on date: Date) -> Decision {
        let already = spent(in: date)
        let after = already + estimatedCost
        if after <= freeAllowanceUSD { return .allowedFree }
        let limit = freeAllowanceUSD + extraLimitUSD
        if after <= limit { return .allowedPaid(billableUSD: after - max(already, freeAllowanceUSD)) }
        return .denied(reason: extraLimitUSD == 0
            ? "This would pass the free quarterly allowance, and the extra-spend limit is $0. Raise the limit to allow billable PACER requests."
            : "This would exceed the extra-spend limit (free allowance + \(extraLimitUSD) USD) for this quarter. Raise the limit to continue.")
    }

    public mutating func record(actualCost: Decimal, on date: Date) {
        spent[Self.quarterKey(for: date), default: 0] += actualCost
    }
}

/// PACER access with the user's own account. Credentials live in the Keychain (entered by the user in Settings; this
/// package never sees or stores them), and every request first passes `PacerBudget.check`.
///
/// Endpoints follow PACER's published PCL API as remembered — **UNVERIFIED against a live login**, because no
/// credentials exist in this repo. The budget and parsing logic are covered by unit tests with a fake fetcher; the first
/// live run should use a tiny `extraLimitUSD` of 0 and the free allowance.
public struct PacerClient: Sendable {
    public static let authURL = URL(string: "https://pacer.login.uscourts.gov/services/cso-auth")!
    public static let caseFindURL = URL(string: "https://pcl.uscourts.gov/pcl-public-api/rest/cases/find")!

    private let fetcher: HTTPFetching
    public private(set) var budget: PacerBudget

    public init(budget: PacerBudget = PacerBudget(), fetcher: HTTPFetching = URLSessionFetcher()) {
        self.budget = budget; self.fetcher = fetcher
    }

    public enum Failure: Error, Equatable { case authFailed, budgetDenied(String), decoding, http(Int) }

    /// Searches PCL for cases whose party name matches. Estimated cost: one results page. Returns the dockets and the
    /// updated budget the caller should persist.
    public mutating func findCases(partyName: String, loginID: String, password: String, now: Date = Date()) async throws -> [CourtDocket] {
        let estimate = budget.estimate(pages: 1)
        let decision = budget.check(estimatedCost: estimate, on: now)
        if case .denied(let reason) = decision { throw Failure.budgetDenied(reason) }

        let token = try await authenticate(loginID: loginID, password: password)
        var req = URLRequest(url: Self.caseFindURL)
        req.httpMethod = "POST"
        req.setValue(token, forHTTPHeaderField: "X-NEXT-GEN-CSO")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["lastName": partyName])
        let (data, status) = try await fetcher.fetch(req)
        guard status == 200 else { throw Failure.http(status) }
        budget.record(actualCost: estimate, on: now)
        return try Self.parseCases(data)
    }

    func authenticate(loginID: String, password: String) async throws -> String {
        var req = URLRequest(url: Self.authURL)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["loginId": loginID, "password": password])
        let (data, status) = try await fetcher.fetch(req)
        guard status == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = object["nextGenCSO"] as? String, !token.isEmpty else { throw Failure.authFailed }
        return token
    }

    static func parseCases(_ data: Data) throws -> [CourtDocket] {
        struct Response: Decodable { var content: [Row]? }
        struct Row: Decodable {
            var caseTitle: String?, caseNumberFull: String?, courtId: String?
            var dateFiled: String?, dateTermed: String?
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data) else { throw Failure.decoding }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = "yyyy-MM-dd"
        return (response.content ?? []).compactMap { r in
            guard let number = r.caseNumberFull, !number.isEmpty else { return nil }
            return CourtDocket(source: "pacer", caseName: r.caseTitle ?? "", docketNumber: number, court: r.courtId ?? "",
                               filedOn: r.dateFiled.flatMap { df.date(from: String($0.prefix(10))) },
                               terminatedOn: r.dateTermed.flatMap { df.date(from: String($0.prefix(10))) })
        }
    }
}
