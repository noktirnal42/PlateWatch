import Fluent
import Foundation
import Vapor

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
                serverReceivedAt: existing.$capturedAt.wrappedValue)
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
                serverReceivedAt: Date())
            return try await receipt.encodeResponse(status: .accepted, for: req)
        }

        let record = Sighting()
        record.capturedAt = dto.capturedAt
        record.geohash6 = dto.geohash6
        record.deviceIDHash = dto.deviceIDHash
        record.fleetConfidence = dto.fleetConfidence
        record.moderationState = outcome.state.rawValue
        record.idempotencyKey = idem
        record.plateText = dto.plate?.text
        record.cropSHA256 = dto.cropHashSHA256
        record.headingDeg = dto.headingDegrees
        if outcome.exactGeoAllowed {
            record.exactLat = dto.exactLatitude
            record.exactLon = dto.exactLongitude
        }
        try await record.save(on: req.db)

        let receipt = SubmissionReceiptDTO(
            sightingID: try record.requireID(),
            moderationState: outcome.state.rawValue,
            serverReceivedAt: Date())
        return try await receipt.encodeResponse(status: .created, for: req)
    }

    @Sendable
    func list(req: Request) async throws -> SightingPageDTO {
        let limit = min(req.query["limit"] ?? 200, 1000)
        var query = Sighting.query(on: req.db)
            .filter(\.$moderationState != "rejected")
            .sort(\.$capturedAt, .descending)
            .limit(limit)
        if let since = try? req.query.get(Date.self, at: "since") {
            query = query.filter(\.$capturedAt > since)
        }
        let rows = try await query.all()
        let items = rows.compactMap { row -> PublicSightingDTO? in
            guard let id = row.id else { return nil }
            return PublicSightingDTO(
                id: id, capturedAt: row.capturedAt, geohash6: row.geohash6,
                plateText: row.plateText, unitNumber: nil,
                fleetConfidence: row.fleetConfidence)
        }
        let next = items.last.map {
            ISO8601DateFormatter().string(from: $0.capturedAt)
        }
        return SightingPageDTO(items: items, nextCursor: next)
    }
}
