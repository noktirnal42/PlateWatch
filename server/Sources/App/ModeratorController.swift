#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Fluent
import Foundation
import Vapor

/// Moderator review queue (M3). Server-rendered HTML — no JavaScript, no
/// third-party assets, so the console works on a phone and loads nothing
/// from anywhere else.
///
/// Access model:
/// - Disabled entirely (404) unless `MODERATOR_TOKEN` is configured with at
///   least 24 characters. There is no default credential.
/// - HTTP Basic auth: any username, password = the token. Compared in
///   constant time.
/// - Each decision form carries an HMAC over (sighting id, decision) keyed
///   by the token, so a cross-site auto-submitted form cannot approve or
///   reject a sighting even when the browser has cached Basic credentials.
///
/// Privacy: the queue only ever shows rows that have no plate text (the
/// ingest path drops plates for anything not fleet-confirmed) — unit number,
/// bucketed geohash, fleet confidence, and the crop hash.
struct ModeratorController: RouteCollection {
    static let minimumTokenLength = 24

    private let token: String?
    private let requireSecondReview: Bool

    init(token: String? = nil, requireSecondReview: Bool = false) {
        self.requireSecondReview = requireSecondReview
        // Reject short tokens outright rather than running a weak console.
        if let token, token.count >= Self.minimumTokenLength {
            self.token = token
        } else {
            self.token = nil
        }
    }

    func boot(routes: any RoutesBuilder) throws {
        let mod = routes.grouped("moderator")
        mod.get(use: queue)
        mod.post("sightings", ":sightingID", "decision", use: decide)
        // JSON API for the Hub's moderator console (moderators only: same token, plus a custom header that a
        // cross-site browser form cannot send).
        let api = mod.grouped("api")
        api.get("queue", use: apiQueue)
        api.post("sightings", ":sightingID", "decision", use: apiDecide)
        api.get("audit", use: apiAudit)
        api.get("takedowns", use: apiTakedowns)
        api.post("takedowns", ":takedownID", "resolve", use: apiResolveTakedown)
    }

    static let apiHeader = "X-PlateWatch-Moderator"

    @Sendable
    func apiQueue(req: Request) async throws -> [APIQueueItem] {
        _ = try authorizedAPI(req)
        let rows = try await Sighting.query(on: req.db)
            .filter(\.$moderationState == RedactionGateService.ModerationState.pending.rawValue)
            .sort(\.$createdAt, .descending)
            .limit(200)
            .all()
        return rows.compactMap { row in
            row.id.map { APIQueueItem(id: $0, capturedAt: row.capturedAt, geohash6: row.geohash6,
                                      unitNumber: row.unitNumber, fleetConfidence: row.fleetConfidence) }
        }
    }

    @Sendable
    func apiDecide(req: Request) async throws -> HTTPStatus {
        _ = try authorizedAPI(req)
        guard let id = req.parameters.get("sightingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "invalid sighting id")
        }
        let body = try req.content.decode(APIDecision.self)
        guard let decision = Decision(rawValue: body.decision) else {
            throw Abort(.badRequest, reason: "decision must be approve or reject")
        }
        guard let row = try await Sighting.find(id, on: req.db) else { throw Abort(.notFound) }
        if row.moderationState == RedactionGateService.ModerationState.pending.rawValue {
            let reviewer = Self.reviewerFingerprint(req)
            if decision == .approve, requireSecondReview {
                if let first = row.firstReviewerFingerprint {
                    guard first != reviewer else { throw Abort(.conflict, reason: "a second reviewer is required") }
                } else {
                    row.firstReviewerFingerprint = reviewer
                    try await row.save(on: req.db)
                    await AuditEntry.record("moderation.first_review", target: id.uuidString,
                                            detail: "state=pending; source=api; reviewer=\(reviewer)", on: req.db)
                    return .noContent
                }
            }
            let previous = row.moderationState
            row.moderationState = decision.resultingState.rawValue
            try await row.save(on: req.db)
            req.logger.info("moderation: \(decision.rawValue) sighting \(id)")
            await AuditEntry.record("moderation.\(decision.rawValue)", target: id.uuidString,
                                    detail: "state=\(previous)→\(row.moderationState); source=api; reviewer=\(Self.reviewerFingerprint(req))", on: req.db)
        }
        return .noContent
    }

    struct APIAudit: Content, Equatable {
        var createdAt: Date?
        var action: String
        var target: String?
        var detail: String?
    }

    /// Newest first, capped. Action + target ID only — the log never holds sighting content.
    @Sendable
    func apiAudit(req: Request) async throws -> [APIAudit] {
        _ = try authorizedAPI(req)
        let limit = min(max(req.query["limit"] ?? 200, 1), 500)
        return try await AuditEntry.query(on: req.db).sort(\.$createdAt, .descending).limit(limit).all()
            .map { APIAudit(createdAt: $0.createdAt, action: $0.action, target: $0.target, detail: $0.detail) }
    }

    struct APITakedown: Content, Equatable {
        var id: UUID
        var createdAt: Date?
        var sightingID: UUID?
        var reason: String
        var contact: String?
    }
    struct APITakedownResolution: Content { var action: String }

    @Sendable
    func apiTakedowns(req: Request) async throws -> [APITakedown] {
        _ = try authorizedAPI(req)
        return try await TakedownRequest.query(on: req.db).filter(\.$status == "open")
            .sort(\.$createdAt, .ascending).limit(200).all().compactMap { r in
                r.id.map { APITakedown(id: $0, createdAt: r.createdAt, sightingID: r.sightingID, reason: r.reason, contact: r.contact) }
            }
    }

    /// `hide` removes the sighting from every public surface for good; `dismiss` closes the request.
    @Sendable
    func apiResolveTakedown(req: Request) async throws -> HTTPStatus {
        _ = try authorizedAPI(req)
        guard let id = req.parameters.get("takedownID", as: UUID.self),
              let request = try await TakedownRequest.find(id, on: req.db) else { throw Abort(.notFound) }
        let body = try req.content.decode(APITakedownResolution.self)
        guard body.action == "hide" || body.action == "dismiss" else { throw Abort(.badRequest, reason: "action must be hide or dismiss") }
        if request.status == "open" {
            if body.action == "hide", let sid = request.sightingID, let sighting = try await Sighting.find(sid, on: req.db) {
                sighting.takenDown = true
                try await sighting.save(on: req.db)
            }
            request.status = body.action == "hide" ? "hidden" : "dismissed"
            try await request.save(on: req.db)
            await AuditEntry.record("takedown.\(body.action)", target: id.uuidString, on: req.db)
        }
        return .noContent
    }

    private func authorizedAPI(_ req: Request) throws -> String {
        guard req.headers.first(name: Self.apiHeader) == "1" else { throw Abort(.forbidden, reason: "missing moderator header") }
        return try authorizedToken(req)
    }

    /// Same privacy rule as the HTML queue: never a plate, only unit number, ~1 km cell and confidence.
    struct APIQueueItem: Content, Equatable {
        var id: UUID
        var capturedAt: Date
        var geohash6: String
        var unitNumber: String?
        var fleetConfidence: Double
    }

    struct APIDecision: Content { var decision: String }

    // MARK: - Routes

    @Sendable
    func queue(req: Request) async throws -> Response {
        let token = try authorizedToken(req)
        let rows = try await Sighting.query(on: req.db)
            .filter(\.$moderationState == RedactionGateService.ModerationState.pending.rawValue)
            .sort(\.$createdAt, .descending)
            .limit(200)
            .all()
        let items = rows.compactMap { row -> QueueItem? in
            guard let id = row.id else { return nil }
            return QueueItem(
                id: id,
                capturedAt: row.capturedAt,
                geohash6: row.geohash6,
                unitNumber: row.unitNumber,
                fleetConfidence: row.fleetConfidence,
                approveCSRF: Self.csrf(token: token, id: id, decision: "approve"),
                rejectCSRF: Self.csrf(token: token, id: id, decision: "reject"))
        }
        let html = Self.renderQueue(items)
        let response = Response(status: .ok, headers: Self.htmlHeaders, body: .init(string: html))
        return response
    }

    @Sendable
    func decide(req: Request) async throws -> Response {
        let token = try authorizedToken(req)
        guard let id = req.parameters.get("sightingID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "invalid sighting id")
        }
        let form = try req.content.decode(DecisionForm.self)
        guard let decision = Decision(rawValue: form.decision) else {
            throw Abort(.badRequest, reason: "decision must be approve or reject")
        }
        guard Self.constantTimeEquals(form.csrf, Self.csrf(token: token, id: id, decision: decision.rawValue)) else {
            throw Abort(.forbidden, reason: "moderation form token mismatch — reload the queue")
        }
        guard let row = try await Sighting.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        // Only pending rows are actionable; a double-submit is a no-op.
        if row.moderationState == RedactionGateService.ModerationState.pending.rawValue {
            let reviewer = Self.reviewerFingerprint(req)
            if decision == .approve, requireSecondReview {
                if let first = row.firstReviewerFingerprint {
                    guard first != reviewer else { throw Abort(.conflict, reason: "a second reviewer is required") }
                } else {
                    row.firstReviewerFingerprint = reviewer
                    try await row.save(on: req.db)
                    await AuditEntry.record("moderation.first_review", target: id.uuidString,
                                            detail: "state=pending; source=html; reviewer=\(reviewer)", on: req.db)
                    return req.redirect(to: "/moderator", redirectType: .normal)
                }
            }
            let previous = row.moderationState
            row.moderationState = decision.resultingState.rawValue
            try await row.save(on: req.db)
            req.logger.info("moderation: \(decision.rawValue) sighting \(id)")
            await AuditEntry.record("moderation.\(decision.rawValue)", target: id.uuidString,
                                    detail: "state=\(previous)→\(row.moderationState); source=html; reviewer=\(Self.reviewerFingerprint(req))", on: req.db)
        }
        return req.redirect(to: "/moderator", redirectType: .normal)
    }

    // MARK: - Auth & CSRF

    private func authorizedToken(_ req: Request) throws -> String {
        guard let token else { throw Abort(.notFound) }
        guard let auth = req.headers.basicAuthorization,
              Self.constantTimeEquals(auth.password, token) else {
            throw Abort(.unauthorized, headers: ["WWW-Authenticate": #"Basic realm="PlateWatch moderator""#])
        }
        return token
    }

    /// Audit identity without persisting a username or credential. API clients
    /// may provide a stable reviewer label; HTML review uses the Basic-auth
    /// username. The digest is only for distinguishing reviewers later.
    static func reviewerFingerprint(_ req: Request) -> String {
        let raw = req.headers.first(name: "X-PlateWatch-Reviewer")
            ?? req.headers.basicAuthorization?.username
            ?? "unknown"
        return reviewerFingerprint(raw)
    }

    static func reviewerFingerprint(_ raw: String) -> String {
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(16).description
    }

    static func csrf(token: String, id: UUID, decision: String) -> String {
        let key = SymmetricKey(data: Data(token.utf8))
        let mac = HMAC<SHA256>.authenticationCode(for: Data("\(id.uuidString)|\(decision)".utf8), using: key)
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// Length-independent constant-time comparison.
    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        var diff = x.count ^ y.count
        for i in 0..<max(x.count, y.count) {
            let xi = i < x.count ? x[i] : 0
            let yi = i < y.count ? y[i] : 0
            diff |= Int(xi ^ yi)
        }
        return diff == 0
    }

    // MARK: - Types

    enum Decision: String {
        case approve, reject
        var resultingState: RedactionGateService.ModerationState {
            switch self {
            case .approve: return .fleetConfirmed
            case .reject: return .rejected
            }
        }
    }

    struct DecisionForm: Content {
        var decision: String
        var csrf: String
    }

    struct QueueItem {
        var id: UUID
        var capturedAt: Date
        var geohash6: String
        var unitNumber: String?
        var fleetConfidence: Double
        var approveCSRF: String
        var rejectCSRF: String
    }

    // MARK: - Rendering

    private static let htmlHeaders: HTTPHeaders = [
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "no-store",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; form-action 'self'; frame-ancestors 'none'",
    ]

    static func renderQueue(_ items: [QueueItem]) -> String {
        let rows: String
        if items.isEmpty {
            rows = #"<p class="empty">Queue is clear. Nothing waiting for review.</p>"#
        } else {
            rows = items.map { item in
                let unit = item.unitNumber.map { escape($0) } ?? "<span class=\"muted\">none</span>"
                let confidence = String(format: "%.0f%%", item.fleetConfidence * 100)
                return """
                <article class="card">
                  <header>
                    <span class="badge">\(confidence) fleet</span>
                    <time>\(escape(ISO8601DateFormatter().string(from: item.capturedAt)))</time>
                  </header>
                  <dl>
                    <dt>Unit</dt><dd>\(unit)</dd>
                    <dt>Area</dt><dd><code>\(escape(item.geohash6))</code> <span class="muted">~1 km cell</span></dd>
                    <dt>ID</dt><dd><code>\(item.id.uuidString)</code></dd>
                  </dl>
                  <div class="actions">
                    <form method="post" action="/moderator/sightings/\(item.id.uuidString)/decision">
                      <input type="hidden" name="decision" value="approve">
                      <input type="hidden" name="csrf" value="\(item.approveCSRF)">
                      <button class="approve" type="submit">Confirm fleet</button>
                    </form>
                    <form method="post" action="/moderator/sightings/\(item.id.uuidString)/decision">
                      <input type="hidden" name="decision" value="reject">
                      <input type="hidden" name="csrf" value="\(item.rejectCSRF)">
                      <button class="reject" type="submit">Reject</button>
                    </form>
                  </div>
                </article>
                """
            }.joined(separator: "\n")
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="robots" content="noindex">
          <title>PlateWatch · Moderator queue</title>
          <style>
            :root {
              --bg: #f5f6f8; --surface: #ffffff; --ink: #14171c; --muted: #5d6572;
              --line: #e2e5ea; --accent: #1d4ed8; --ok: #15803d; --bad: #b91c1c;
              --badge: #e0e7ff; --badge-ink: #3730a3;
            }
            @media (prefers-color-scheme: dark) {
              :root:not([data-theme="light"]) {
                --bg: #0d1015; --surface: #161b22; --ink: #e6e9ef; --muted: #8b95a5;
                --line: #262d37; --accent: #6ea8ff; --ok: #4ade80; --bad: #f87171;
                --badge: #1e2a4a; --badge-ink: #a5b8ff;
              }
            }
            :root[data-theme="dark"] {
              --bg: #0d1015; --surface: #161b22; --ink: #e6e9ef; --muted: #8b95a5;
              --line: #262d37; --accent: #6ea8ff; --ok: #4ade80; --bad: #f87171;
              --badge: #1e2a4a; --badge-ink: #a5b8ff;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0; background: var(--bg); color: var(--ink);
              font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            }
            main { max-width: 760px; margin: 0 auto; padding: 24px 16px 48px; }
            h1 { font-size: 22px; margin: 0 0 4px; letter-spacing: -0.01em; }
            .lede { color: var(--muted); margin: 0 0 20px; font-size: 14px; }
            .card {
              background: var(--surface); border: 1px solid var(--line);
              border-radius: 14px; padding: 16px; margin-bottom: 12px;
            }
            .card header { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; }
            .badge {
              background: var(--badge); color: var(--badge-ink); font-weight: 600;
              font-size: 13px; padding: 3px 10px; border-radius: 999px;
            }
            time { color: var(--muted); font-size: 13px; font-variant-numeric: tabular-nums; }
            dl { display: grid; grid-template-columns: 56px 1fr; gap: 6px 12px; margin: 12px 0; font-size: 14px; }
            dt { color: var(--muted); }
            dd { margin: 0; overflow-wrap: anywhere; }
            code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
            .muted { color: var(--muted); }
            .actions { display: flex; gap: 10px; flex-wrap: wrap; }
            .actions form { flex: 1 1 140px; margin: 0; }
            button {
              width: 100%; min-height: 44px; border-radius: 10px; border: 1px solid var(--line);
              font-family: inherit; font-weight: 600; font-size: 15px; cursor: pointer; background: var(--surface); color: var(--ink);
            }
            button.approve { background: var(--ok); border-color: var(--ok); color: #fff; }
            button.reject { color: var(--bad); }
            button:focus-visible { outline: 3px solid var(--accent); outline-offset: 2px; }
            .empty {
              text-align: center; color: var(--muted); padding: 48px 16px;
              border: 1px dashed var(--line); border-radius: 14px;
            }
          </style>
        </head>
        <body>
          <main>
            <h1>Moderator queue</h1>
            <p class="lede">Pending sightings awaiting a fleet decision. Plates are never shown here: non-fleet plates are not stored.</p>
            \(rows)
          </main>
        </body>
        </html>
        """
    }

    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&#39;"
            default: out.append(ch)
            }
        }
        return out
    }
}
