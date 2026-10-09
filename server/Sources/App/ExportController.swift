import Foundation
import Vapor

/// Renderers for public dataset exports. Pure functions so they're unit-
/// testable without a database; controllers just query and hand off rows.
public enum ExportRenderer {

    public struct Row: Sendable {
        public var id: UUID
        public var capturedAt: Date
        public var geohash6: String
        public var plateText: String?
        public var unitNumber: String?
        public var fleetConfidence: Double

        public init(id: UUID, capturedAt: Date, geohash6: String,
                    plateText: String?, unitNumber: String?, fleetConfidence: Double) {
            self.id = id; self.capturedAt = capturedAt; self.geohash6 = geohash6
            self.plateText = plateText; self.unitNumber = unitNumber
            self.fleetConfidence = fleetConfidence
        }
    }

    /// RFC 4180-ish CSV with a header row. Cells are quoted when needed.
    public static func csv(_ rows: [Row]) -> String {
        var out = "id,captured_at,geohash6,plate_text,unit_number,fleet_confidence\n"
        let iso = ISO8601DateFormatter()
        for r in rows {
            out += [
                r.id.uuidString,
                iso.string(from: r.capturedAt),
                r.geohash6,
                r.plateText.map(csvEscape) ?? "",
                r.unitNumber.map(csvEscape) ?? "",
                String(format: "%.3f", r.fleetConfidence),
            ].joined(separator: ",") + "\n"
        }
        return out
    }

    private static func csvEscape(_ s: String) -> String {
        s.contains(",") || s.contains("\"") || s.contains("\n")
            ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
            : s
    }

    /// GeoJSON FeatureCollection using geohash-6 cell centers. Exact fleet
    /// coordinates are NOT in the public export — buckets only.
    public static func geoJSON(_ rows: [Row]) -> String {
        var features: [String] = []
        let iso = ISO8601DateFormatter()
        for r in rows {
            guard let center = geohashCenter(r.geohash6) else { continue }
            let props: [String: String] = [
                "id": jsonString(r.id.uuidString),
                "captured_at": jsonString(iso.string(from: r.capturedAt)),
                "fleet_confidence": String(format: "%.3f", r.fleetConfidence),
                "unit_number": r.unitNumber.map(jsonString) ?? "null",
            ]
            let propStr = props.sorted { $0.key < $1.key }
                .map { "\"\($0.key)\":\($0.value)" }.joined(separator: ",")
            features.append("""
            {"type":"Feature","geometry":{"type":"Point","coordinates":[\(center.lon),\(center.lat)]},"properties":{\(propStr)}}
            """)
        }
        return """
        {"type":"FeatureCollection","features":[\(features.joined(separator: ","))]}
        """
    }

    private static func jsonString(_ s: String) -> String {
        let escaped = s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    /// Minimal self-contained geohash-6 decoder (server has no PlateKit).
    public static func geohashCenter(_ hash: String) -> (lat: Double, lon: Double)? {
        let alphabet = Array("0123456789bcdefghjkmnpqrstuvwxyz")
        var lat = (-90.0, 90.0), lon = (-180.0, 180.0)
        var isLon = true
        for char in hash.lowercased() {
            guard let idx = alphabet.firstIndex(of: char) else { return nil }
            for bitIndex in stride(from: 4, through: 0, by: -1) {
                let bit = (idx >> bitIndex) & 1
                if isLon {
                    let m = (lon.0 + lon.1) / 2
                    if bit == 1 { lon.0 = m } else { lon.1 = m }
                } else {
                    let m = (lat.0 + lat.1) / 2
                    if bit == 1 { lat.0 = m } else { lat.1 = m }
                }
                isLon.toggle()
            }
        }
        return ((lat.0 + lat.1) / 2, (lon.0 + lon.1) / 2)
    }
}

/// GET /v1/export.csv / GET /v1/export.geojson — public dataset dumps
/// (fleet-confirmed sightings only; buckets, never exact coordinates).
struct ExportController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let v1 = routes.grouped("v1", "export")
        v1.get("sightings.csv", use: csv)
        v1.get("sightings.geojson", use: geoJSON)
    }

    @Sendable
    func csv(req: Request) async throws -> Response {
        let rows = try await fleetConfirmedRows(on: req.db)
        let body = ExportRenderer.csv(rows)
        let response = Response(status: .ok, body: .init(string: body))
        response.headers.contentType = .init(type: "text", subType: "csv")
        return response
    }

    @Sendable
    func geoJSON(req: Request) async throws -> Response {
        let rows = try await fleetConfirmedRows(on: req.db)
        let body = ExportRenderer.geoJSON(rows)
        let response = Response(status: .ok, body: .init(string: body))
        response.headers.contentType = .init(type: "application", subType: "geo+json")
        return response
    }

    private func fleetConfirmedRows(on db: any Database) async throws -> [ExportRenderer.Row] {
        try await Sighting.query(on: db)
            .filter(\.$moderationState == "fleetConfirmed")
            .sort(\.$capturedAt, .descending)
            .limit(50_000)
            .all()
            .compactMap { s in
                guard let id = s.id else { return nil }
                return ExportRenderer.Row(
                    id: id, capturedAt: s.capturedAt, geohash6: s.geohash6,
                    plateText: s.plateText, unitNumber: nil,
                    fleetConfidence: s.fleetConfidence)
            }
    }
}

import Fluent
