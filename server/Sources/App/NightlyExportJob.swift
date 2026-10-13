import Fluent
import Foundation
import Vapor

/// Nightly public export: runs a timer at 03:00 UTC daily and writes
/// fleet-confirmed sightings to CSV/GeoJSON snapshots. Uses the same
/// query + renderer as the live `GET /v1/export/*` endpoints.
final class NightlyExportJob: LifecycleHandler {

    private var timer: DispatchSourceTimer?

    func willBoot(_ app: Application) throws {
        let queue = DispatchQueue(label: "org.platewatch.nightly-export", qos: .utility)
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: nextFireAt03UTC(),
                       repeating: .never) // we reschedule after each fire
        timer.setEventHandler { [weak self] in
            self?.runExport(app: app)
        }
        timer.resume()
        self.timer = timer
    }

    func shutdown(_ app: Application) {
        timer?.cancel()
        timer = nil
    }

    private func nextFireAt03UTC() -> DispatchTime {
        let now = Date()
        guard let utc = TimeZone(identifier: "UTC") else {
            return DispatchTime.now() + 86_400 // fallback: 24h
        }
        var comps = Calendar.current.dateComponents(in: utc, from: now)
        comps.hour = 3
        comps.minute = 0
        comps.second = 0
        guard let next = Calendar.current.nextDate(after: now,
                                                    matching: comps,
                                                    matchingPolicy: .nextTimePreservingSmallerComponents) else {
            return DispatchTime.now() + 86_400 // fallback: 24h
        }
        return DispatchTime.now() + next.timeIntervalSince(now)
    }

    private func runExport(app: Application) {
        app.logger.info("Nightly export started")
        Task {
            do {
                let dir = URL(fileURLWithPath: Environment.get("EXPORT_DIR") ?? "Public/exports")
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

                // Query + render exactly like the live endpoint.
                let rows = try await Sighting.query(on: app.db)
                    .filter(\.$moderationState == "fleetConfirmed")
                    .sort(\.$capturedAt, .descending)
                    .limit(50_000)
                    .all()
                    .compactMap { s -> ExportRenderer.Row? in
                        guard let id = s.id else { return nil }
                        return ExportRenderer.Row(
                            id: id, capturedAt: s.capturedAt, geohash6: s.geohash6,
                            plateText: s.plateText, unitNumber: s.unitNumber,
                            fleetConfidence: s.fleetConfidence)
                    }

                let csv = ExportRenderer.csv(rows)
                let geo = ExportRenderer.geoJSON(rows)
                let timestamp = ISO8601DateFormatter().string(from: Date())
                    .replacingOccurrences(of: ":", with: "-")
                    .replacingOccurrences(of: ".", with: "-")

                let csvPath = dir.appendingPathComponent("sightings-\(timestamp).csv")
                let geoPath = dir.appendingPathComponent("sightings-\(timestamp).geojson")

                try csv.write(to: csvPath, atomically: true, encoding: .utf8)
                try geo.write(to: geoPath, atomically: true, encoding: .utf8)

                let latestCSV = dir.appendingPathComponent("sightings.csv")
                let latestGEO = dir.appendingPathComponent("sightings.geojson")
                if FileManager.default.fileExists(atPath: latestCSV.path) {
                    try FileManager.default.removeItem(at: latestCSV)
                }
                if FileManager.default.fileExists(atPath: latestGEO.path) {
                    try FileManager.default.removeItem(at: latestGEO)
                }
                try FileManager.default.createSymbolicLink(at: latestCSV, withDestinationURL: csvPath)
                try FileManager.default.createSymbolicLink(at: latestGEO, withDestinationURL: geoPath)

                app.logger.info("Nightly export written: \(csvPath.lastPathComponent) (\(rows.count) rows)")

                // Reschedule for next day
                self.timer?.schedule(deadline: self.nextFireAt03UTC(), repeating: .never)
            } catch {
                app.logger.error("Nightly export failed: \(error)")
            }
        }
    }
}
extension NightlyExportJob: @unchecked Sendable {}