import Fluent
import Foundation
import Vapor

/// Publication guardrails (docs/FEED-SOURCES.md §6, LEGAL-ETHICS): nothing is public the moment it is confirmed, and
/// nothing is kept forever.
///
/// - `publishDelay` (env `PUBLISH_DELAY_HOURS`, default 24, max 720): a fleet-confirmed sighting only appears on public
///   surfaces (feed, exports, aggregates, agency report) once it is at least this old, so the feed cannot be used to follow a
///   vehicle in near-real time.
/// - `retention` (env `RETENTION_DAYS`, default 21, 1…365): rows older than this are deleted, including any plate text.
/// - A sighting a person asked to take down (`taken_down`) is never published, whatever its age.
struct PublicationPolicy: Sendable, Equatable {
    var publishDelay: TimeInterval
    var retention: TimeInterval

    static let defaultDelayHours = 24.0
    static let defaultRetentionDays = 21.0

    static func parse(delayHours: String?, retentionDays: String?) -> PublicationPolicy {
        let delay = Double(delayHours ?? "").map { min(max($0, 0), 720) } ?? defaultDelayHours
        let days = Double(retentionDays ?? "").map { min(max($0, 1), 365) } ?? defaultRetentionDays
        return PublicationPolicy(publishDelay: delay * 3600, retention: days * 86_400)
    }

    static func fromEnvironment() -> PublicationPolicy {
        parse(delayHours: Environment.get("PUBLISH_DELAY_HOURS"), retentionDays: Environment.get("RETENTION_DAYS"))
    }

    /// Rows captured after this instant are not public yet.
    func publishCutoff(now: Date = Date()) -> Date { now.addingTimeInterval(-publishDelay) }
    /// Rows captured before this instant are purged.
    func purgeCutoff(now: Date = Date()) -> Date { now.addingTimeInterval(-retention) }
}

extension Sighting {
    /// The only query public surfaces may start from: fleet-confirmed, not taken down, and old enough to publish.
    static func publicQuery(on db: any Database, policy: PublicationPolicy = .fromEnvironment(), now: Date = Date()) -> QueryBuilder<Sighting> {
        Sighting.query(on: db)
            .filter(\.$moderationState == RedactionGateService.ModerationState.fleetConfirmed.rawValue)
            .filter(\.$takenDown == false)
            .filter(\.$capturedAt <= policy.publishCutoff(now: now))
    }

    /// Deletes every row past retention. Returns how many were removed.
    @discardableResult
    static func purgeExpired(on db: any Database, policy: PublicationPolicy = .fromEnvironment(), now: Date = Date()) async throws -> Int {
        // Rows still published to CloudKit wait for the publish tool to withdraw the public record first; deleting
        // them here would orphan a world-readable record past the retention promise.
        let cutoff = policy.purgeCutoff(now: now)
        let expired = try await Sighting.query(on: db).filter(\.$capturedAt < cutoff).filter(\.$publishedAt == nil).count()
        if expired > 0 { try await Sighting.query(on: db).filter(\.$capturedAt < cutoff).filter(\.$publishedAt == nil).delete() }
        return expired
    }
}

/// Append-only record of moderator and takedown actions: who-did-what to which row, never the content itself.
final class AuditEntry: Model, @unchecked Sendable {
    static let schema = "audit_log"
    @ID(key: .id) var id: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @Field(key: "action") var action: String
    @OptionalField(key: "target") var target: String?
    @OptionalField(key: "detail") var detail: String?
    init() {}
    init(action: String, target: String? = nil, detail: String? = nil) {
        self.action = action; self.target = target; self.detail = detail
    }

    static func record(_ action: String, target: String? = nil, detail: String? = nil, on db: any Database) async {
        try? await AuditEntry(action: action, target: target, detail: detail).save(on: db)
    }
}

/// A public request to remove a sighting from publication.
final class TakedownRequest: Model, @unchecked Sendable {
    static let schema = "takedown_requests"
    @ID(key: .id) var id: UUID?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?
    @OptionalField(key: "sighting_id") var sightingID: UUID?
    @Field(key: "reason") var reason: String
    @OptionalField(key: "contact") var contact: String?
    /// open → hidden | dismissed
    @Field(key: "status") var status: String
    init() {}
    init(sightingID: UUID?, reason: String, contact: String?) {
        self.sightingID = sightingID; self.reason = reason; self.contact = contact; self.status = "open"
    }
}

struct CreateAuditLog: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(AuditEntry.schema)
            .id()
            .field("created_at", .datetime)
            .field("action", .string, .required)
            .field("target", .string)
            .field("detail", .string)
            .create()
    }
    func revert(on database: any Database) async throws { try await database.schema(AuditEntry.schema).delete() }
}

struct CreateTakedownRequests: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(TakedownRequest.schema)
            .id()
            .field("created_at", .datetime)
            .field("sighting_id", .uuid)
            .field("reason", .string, .required)
            .field("contact", .string)
            .field("status", .string, .required)
            .create()
    }
    func revert(on database: any Database) async throws { try await database.schema(TakedownRequest.schema).delete() }
}

struct AddSightingTakedown: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Sighting.schema)
            .field("taken_down", .bool, .required, .sql(.default(false)))
            .update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(Sighting.schema).deleteField("taken_down").update()
    }
}

struct AddSightingFirstReviewer: AsyncMigration {
    func prepare(on database: any Database) async throws {
        try await database.schema(Sighting.schema)
            .field("first_reviewer_fingerprint", .string)
            .update()
    }
    func revert(on database: any Database) async throws {
        try await database.schema(Sighting.schema)
            .deleteField("first_reviewer_fingerprint")
            .update()
    }
}

/// Public intake for takedown requests, plus the daily retention purge.
struct TakedownController: RouteCollection {
    static let maxReason = 1000, maxContact = 200

    struct Input: Content { var sightingID: UUID?; var reason: String; var contact: String? }

    /// Pure validation, kept out of the route so it is testable without a database.
    static func validate(_ input: Input) -> String? {
        let reason = input.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        if reason.isEmpty { return "reason is required" }
        if reason.count > maxReason { return "reason is too long" }
        if (input.contact ?? "").count > maxContact { return "contact is too long" }
        return nil
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1").post("takedowns", use: submit)
    }

    @Sendable
    func submit(req: Request) async throws -> HTTPStatus {
        let input = try req.content.decode(Input.self)
        if let problem = Self.validate(input) { throw Abort(.badRequest, reason: problem) }
        let record = TakedownRequest(sightingID: input.sightingID,
                                     reason: input.reason.trimmingCharacters(in: .whitespacesAndNewlines),
                                     contact: input.contact?.trimmingCharacters(in: .whitespacesAndNewlines))
        try await record.save(on: req.db)
        await AuditEntry.record("takedown.requested", target: record.id?.uuidString, on: req.db)
        return .accepted
    }
}

/// Deletes rows past retention once a day.
final class RetentionJob: LifecycleHandler, @unchecked Sendable {
    private var timer: DispatchSourceTimer?

    func willBoot(_ app: Application) throws {
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "org.platewatch.retention", qos: .utility))
        timer.schedule(deadline: .now() + 60, repeating: .seconds(86_400))
        timer.setEventHandler {
            Task {
                if let removed = try? await Sighting.purgeExpired(on: app.db), removed > 0 {
                    app.logger.info("retention: purged \(removed) sighting(s)")
                    await AuditEntry.record("retention.purged", detail: "\(removed) rows", on: app.db)
                }
            }
        }
        timer.resume()
        self.timer = timer
    }

    func shutdown(_ app: Application) { timer?.cancel(); timer = nil }
}
