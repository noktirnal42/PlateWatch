import Fluent
import Foundation
import Vapor

/// Delta-sync page cursor: the last row's captured timestamp plus its ID.
/// Second-precision timestamps collide constantly (client submissions land
/// on whole seconds), so the ID tiebreaker is what keeps pages from
/// skipping or looping rows at the boundary.
struct SightingCursor: Equatable {
    var timestamp: Date
    var lastID: UUID

    nonisolated(unsafe) static let tokenFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    nonisolated(unsafe) static let plainFormatter = ISO8601DateFormatter()

    var token: String {
        "\(Self.tokenFormatter.string(from: timestamp))|\(lastID.uuidString)"
    }

    /// Accepts the compound token, or a bare ISO-8601 date (legacy `since`).
    static func parse(_ raw: String?) -> SightingCursor? {
        guard let raw, !raw.isEmpty else { return nil }
        let parts = raw.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[1])) else { return nil }
        guard let t = tokenFormatter.date(from: String(parts[0]))
                ?? plainFormatter.date(from: String(parts[0])) else { return nil }
        return SightingCursor(timestamp: t, lastID: id)
    }
}

/// POST /v1/sightings — community detection ingest.
/// GET  /v1/sightings?cursor=… — delta read for sync clients.
struct SightingsController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1")
        let sightings = v1.grouped("sightings")
        sightings.post(use: submit)
        sightings.get(use: list)
    }

    @Sendable
    func submit(req: Request) async throws -> Response {
        let dto = try req.content.decode(SightingSubmissionDTO.self)
        guard let idem = req.headers["Idempotency-Key"].first, !idem.isEmpty else {
            throw Abort(.badRequest, reason: "Idempotency-Key header required")
        }

        // Idempotent replay: return the original receipt.
        if let existing = try await Sighting.query(on: req.db)
            .filter(\.$idempotencyKey == idem).first() {
            let receipt = SubmissionReceiptDTO(
                sightingID: try existing.requireID(),
                moderationState: existing.moderationState,
                serverReceivedAt: existing.createdAt ?? Date(),
                idempotencyKey: existing.idempotencyKey,
                operatorConfirmed: true)
            return try await receipt.encodeResponse(status: .ok, for: req)
        }

        // Device reputation pre-check.
        if let rep = try await DeviceReputation.query(on: req.db)
            .filter(\.$deviceIDHash == dto.deviceIDHash).first(),
           rep.bannedReason != nil {
            throw Abort(.forbidden, reason: "device banned: \(rep.bannedReason!)")
        }

        let outcome = RedactionGateService.evaluate(dto)
        guard outcome.state != .rejected else {
            // Hard floor: drop without storing. Still a 2xx receipt so
            // clients can prune their outbox — but marked rejected.
            let receipt = SubmissionReceiptDTO(
                sightingID: UUID(), moderationState: outcome.state.rawValue,
                serverReceivedAt: Date(), idempotencyKey: idem,
                operatorConfirmed: dto.userConfirmed)
            await AuditEntry.record("submission.rejected", target: idem,
                                    detail: "reason=\(outcome.dropReason ?? "gate")", on: req.db)
            return try await receipt.encodeResponse(status: .accepted, for: req)
        }

        let record = Sighting()
        record.capturedAt = dto.capturedAt
        record.geohash6 = dto.geohash6
        record.deviceIDHash = dto.deviceIDHash
        record.fleetConfidence = dto.fleetConfidence
        record.moderationState = outcome.state.rawValue
        record.idempotencyKey = idem
        // LEGAL-ETHICS Rule 1: a plate is only persisted once the sighting is
        // fleet-confirmed. Pending/redacted rows keep the fleet signal
        // (unit, confidence, crop hash) but never the plate text.
        record.plateText = outcome.state == .fleetConfirmed ? dto.plate?.text : nil
        record.unitNumber = dto.markings?.unitNumber
        // Identity metadata is about the organisation / jurisdiction, never a person or a plate.
        record.agencyKey = dto.identity?.agency?.agencyKey
        record.agencyName = dto.identity?.agency?.name
        record.agencyNeedsReview = dto.identity?.agency?.needsReview
        record.plateState = dto.identity?.plate?.state
        record.cropSHA256 = dto.cropHashSHA256
        record.headingDeg = dto.headingDegrees
        if outcome.exactGeoAllowed {
            record.exactLat = dto.exactLatitude
            record.exactLon = dto.exactLongitude
        }
        try await record.save(on: req.db)
        await AuditEntry.record("submission.accepted", target: record.id?.uuidString,
                                detail: "state=\(outcome.state.rawValue); operatorConfirmed=\(dto.userConfirmed.map(String.init) ?? "legacy")", on: req.db)

        let receipt = SubmissionReceiptDTO(
            sightingID: try record.requireID(),
            moderationState: outcome.state.rawValue,
            serverReceivedAt: record.createdAt ?? Date(),
            idempotencyKey: record.idempotencyKey,
            operatorConfirmed: dto.userConfirmed)
        return try await receipt.encodeResponse(status: .created, for: req)
    }

    @Sendable
    func list(req: Request) async throws -> SightingPageDTO {
        let limit = min(req.query["limit"] ?? 200, 1000)
        // Public feed: fleet-confirmed rows only. Pending/redacted rows are
        // review-queue material and must never reach public clients.
        var query = Sighting.publicQuery(on: req.db)
            .sort(\.$capturedAt, .descending)
            .sort(\.$id, .descending)
            .limit(limit)

        if let raw = req.query[String.self, at: "cursor"], !raw.isEmpty {
            if let cursor = SightingCursor.parse(raw) {
                // Resume strictly after the boundary row: strictly older
                // rows, or rows sharing its timestamp with a lower ID
                // (matching the capturedAt DESC, id DESC ordering).
                let t = cursor.timestamp
                let lastID = cursor.lastID
                query = query.group(.or) { group in
                    group.filter(\.$capturedAt < t)
                    group.filter(\.$capturedAt == t).filter(\.$id < lastID)
                }
            } else if let since = SightingCursor.plainFormatter.date(from: raw) {
                // Legacy ad-hoc `since` filter (no resume guarantee).
                query = query.filter(\.$capturedAt > since)
            }
        }

        let rows = try await query.all()
        let items = rows.compactMap { row -> PublicSightingDTO? in
            guard let id = row.id else { return nil }
            return PublicSightingDTO(
                id: id, capturedAt: row.capturedAt, geohash6: row.geohash6,
                plateText: row.plateText, unitNumber: row.unitNumber,
                fleetConfidence: row.fleetConfidence,
                // A flagged (ambiguous/partial) identity is not published as fact.
                agencyKey: row.agencyNeedsReview == false ? row.agencyKey : nil,
                agencyName: row.agencyNeedsReview == false ? row.agencyName : nil)
        }
        let next = items.last.flatMap { dto in
            SightingCursor(timestamp: dto.capturedAt, lastID: dto.id).token
        }
        return SightingPageDTO(items: items, nextCursor: next)
    }
}
