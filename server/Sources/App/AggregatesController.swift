import Fluent
import Foundation
import Vapor

/// k-anonymity for public aggregates (M4, decision 2026-10-11: agency
/// aggregates with k-anonymity). Any bucket with fewer than `k` sightings is
/// withheld, so a published count can never single out one vehicle or one
/// person's route.
enum KAnonymity {
    /// Minimum sightings per published bucket.
    static let k = 5

    struct Bucket<Key: Equatable & Sendable>: Equatable, Sendable {
        var key: Key
        var count: Int
    }

    struct Suppressed<Key: Equatable & Sendable>: Equatable, Sendable {
        var published: [Bucket<Key>]
        var withheldBuckets: Int
    }

    /// Keeps buckets with at least `k` items, sorted by key for stable output.
    static func suppress<Key: Hashable & Comparable & Sendable>(
        _ counts: [Key: Int], k: Int = KAnonymity.k
    ) -> Suppressed<Key> {
        let kept = counts.filter { $0.value >= k }
            .map { Bucket(key: $0.key, count: $0.value) }
            .sorted { $0.key < $1.key }
        return Suppressed(published: kept, withheldBuckets: counts.count - kept.count)
    }
}

/// GET /v1/aggregates/heatmap — fleet-confirmed sightings bucketed by
/// geohash-6 cell (~1 km) and by UTC day, with k-anonymity applied.
///
/// Query:
/// - `since`, `until`: ISO-8601 instants. Default window: last 30 days.
///   Maximum window: 366 days.
/// - `agencyID`: optional. Restricts to sightings whose linked vehicle belongs
///   to that agency. Vehicle linking is not yet automatic, so agency-scoped
///   results are sparse until linking ships (see ROADMAP M3).
struct AggregatesController: RouteCollection {
    static let maxWindow: TimeInterval = 366 * 86_400

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1", "aggregates").get("heatmap", use: heatmap)
    }

    struct HeatmapCell: Content, Equatable {
        var geohash6: String
        var count: Int
    }

    struct TimelineDay: Content, Equatable {
        var date: String
        var count: Int
    }

    struct HeatmapResponse: Content, Equatable {
        var k: Int
        var since: Date
        var until: Date
        var cells: [HeatmapCell]
        var timeline: [TimelineDay]
        /// Cells / days omitted for being under k. Reported as a count only.
        var withheldCells: Int
        var withheldDays: Int
    }

    @Sendable
    func heatmap(req: Request) async throws -> HeatmapResponse {
        let until = try parseDate(req.query[String.self, at: "until"]) ?? Date()
        let since = try parseDate(req.query[String.self, at: "since"])
            ?? until.addingTimeInterval(-30 * 86_400)
        guard since < until else {
            throw Abort(.badRequest, reason: "since must be before until")
        }
        guard until.timeIntervalSince(since) <= Self.maxWindow else {
            throw Abort(.badRequest, reason: "window may not exceed 366 days")
        }
        let agencyID = try req.query[String.self, at: "agencyID"].map { raw -> UUID in
            guard let id = UUID(uuidString: raw) else {
                throw Abort(.badRequest, reason: "agencyID must be a UUID")
            }
            return id
        }

        var query = Sighting.query(on: req.db)
            .filter(\.$moderationState == RedactionGateService.ModerationState.fleetConfirmed.rawValue)
            .filter(\.$capturedAt >= since)
            .filter(\.$capturedAt <= until)
            .with(\.$vehicle)
        let rows = try await query.all()
        let scoped = rows.filter { row in
            guard let agencyID else { return true }
            return row.vehicle?.$agency.id == agencyID
        }

        var byCell: [String: Int] = [:]
        var byDay: [String: Int] = [:]
        for row in scoped {
            byCell[row.geohash6, default: 0] += 1
            byDay[Self.dayFormatter.string(from: row.capturedAt), default: 0] += 1
        }

        let cells = KAnonymity.suppress(byCell)
        let days = KAnonymity.suppress(byDay)
        return HeatmapResponse(
            k: KAnonymity.k,
            since: since,
            until: until,
            cells: cells.published.map { HeatmapCell(geohash6: $0.key, count: $0.count) },
            timeline: days.published.map { TimelineDay(date: $0.key, count: $0.count) },
            withheldCells: cells.withheldBuckets,
            withheldDays: days.withheldBuckets)
    }

    private func parseDate(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        guard let date = Self.isoFormatter.date(from: raw) ?? Self.plainISO.date(from: raw) else {
            throw Abort(.badRequest, reason: "dates must be ISO-8601")
        }
        return date
    }

    nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let plainISO = ISO8601DateFormatter()

    nonisolated(unsafe) static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
}
