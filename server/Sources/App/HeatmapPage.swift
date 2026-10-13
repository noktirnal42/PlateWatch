import Foundation
import Vapor

/// Public, read-only heatmap page (M4). Server-rendered with inline SVG: no
/// scripts, no map tiles, no third-party requests, so nothing about a reader
/// is sent anywhere. Plots only the k-anonymous cells that the aggregate
/// report already published.
enum HeatmapPage {

    static let headers: HTTPHeaders = [
        "Content-Type": "text/html; charset=utf-8",
        "Cache-Control": "public, max-age=300",
        "X-Content-Type-Options": "nosniff",
        "Referrer-Policy": "no-referrer",
        "Content-Security-Policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; frame-ancestors 'none'",
    ]

    static func render(_ report: AggregatesController.HeatmapResponse) -> String {
        let dateRange = "\(day(report.since)) to \(day(report.until))"
        let body: String
        if report.cells.isEmpty && report.timeline.isEmpty {
            body = #"<p class="empty">No area has reached the publication threshold in this window.</p>"#
        } else {
            body = """
            <section class="panel" aria-labelledby="map-h">
              <h2 id="map-h">Where fleet vehicles were seen</h2>
              \(scatter(report.cells))
            </section>
            <section class="panel" aria-labelledby="time-h">
              <h2 id="time-h">Sightings per day</h2>
              \(timeline(report.timeline))
            </section>
            <section class="panel" aria-labelledby="table-h">
              <h2 id="table-h">Published areas</h2>
              <table>
                <thead><tr><th scope="col">Area (geohash-6, ~1 km)</th><th scope="col">Sightings</th></tr></thead>
                <tbody>
                  \(report.cells.map { "<tr><td><code>\(escape($0.geohash6))</code></td><td>\($0.count)</td></tr>" }.joined(separator: "\n"))
                </tbody>
              </table>
            </section>
            """
        }

        return """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <meta name="description" content="Aggregate, privacy-preserving counts of fleet vehicle sightings.">
          <title>PlateWatch · Fleet sighting heatmap</title>
          <style>
            :root {
              --bg: #f5f6f8; --surface: #ffffff; --ink: #14171c; --muted: #5d6572;
              --line: #e2e5ea; --accent: #b45309; --dot: #f59e0b; --bar: #1d4ed8;
            }
            @media (prefers-color-scheme: dark) {
              :root:not([data-theme="light"]) {
                --bg: #0d1015; --surface: #161b22; --ink: #e6e9ef; --muted: #8b95a5;
                --line: #262d37; --accent: #fbbf24; --dot: #fbbf24; --bar: #6ea8ff;
              }
            }
            :root[data-theme="dark"] {
              --bg: #0d1015; --surface: #161b22; --ink: #e6e9ef; --muted: #8b95a5;
              --line: #262d37; --accent: #fbbf24; --dot: #fbbf24; --bar: #6ea8ff;
            }
            * { box-sizing: border-box; }
            body {
              margin: 0; background: var(--bg); color: var(--ink);
              font: 16px/1.5 -apple-system, BlinkMacSystemFont, "SF Pro Text", system-ui, sans-serif;
            }
            main { max-width: 900px; margin: 0 auto; padding: 24px 16px 48px; }
            h1 { font-size: 26px; margin: 0 0 4px; letter-spacing: -0.02em; }
            h2 { font-size: 16px; margin: 0 0 12px; }
            .lede { color: var(--muted); margin: 0 0 20px; font-size: 14px; max-width: 64ch; }
            .meta { display: flex; flex-wrap: wrap; gap: 8px; margin-bottom: 20px; }
            .chip {
              background: var(--surface); border: 1px solid var(--line); border-radius: 999px;
              padding: 4px 12px; font-size: 13px; color: var(--muted);
            }
            .chip strong { color: var(--ink); font-weight: 600; }
            .panel {
              background: var(--surface); border: 1px solid var(--line);
              border-radius: 16px; padding: 18px; margin-bottom: 16px;
            }
            svg { width: 100%; height: auto; display: block; }
            .grid line { stroke: var(--line); stroke-width: 1; }
            .dot { fill: var(--dot); fill-opacity: 0.55; stroke: var(--accent); stroke-width: 1.5; }
            .bar { fill: var(--bar); }
            .axis { fill: var(--muted); font-size: 12px; font-family: ui-monospace, Menlo, monospace; }
            table { width: 100%; border-collapse: collapse; font-size: 14px; }
            th, td { text-align: left; padding: 8px 6px; border-bottom: 1px solid var(--line); }
            th { color: var(--muted); font-weight: 600; }
            td:last-child, th:last-child { text-align: right; font-variant-numeric: tabular-nums; }
            code { font: 13px ui-monospace, SFMono-Regular, Menlo, monospace; }
            .empty {
              text-align: center; color: var(--muted); padding: 48px 16px;
              border: 1px dashed var(--line); border-radius: 16px;
            }
            footer { color: var(--muted); font-size: 13px; margin-top: 24px; }
          </style>
        </head>
        <body>
          <main>
            <h1>Fleet sighting heatmap</h1>
            <p class="lede">Counts of fleet-confirmed sightings by area and by day. Areas and days with fewer than \(report.k) sightings are withheld, so no single vehicle or route can be picked out.</p>
            <div class="meta">
              <span class="chip">Window <strong>\(escape(dateRange))</strong></span>
              <span class="chip">Areas shown <strong>\(report.cells.count)</strong></span>
              <span class="chip">Areas withheld <strong>\(report.withheldCells)</strong></span>
            </div>
            \(body)
            <footer>Threshold k = \(report.k). Areas are ~1 km geohash cells. Times are UTC. No plates or per-sighting locations are shown.</footer>
          </main>
        </body>
        </html>
        """
    }

    // MARK: - Charts

    /// Cells as dots on an equirectangular plot fitted to their bounding box.
    /// Dot area scales with count so the densest areas read first.
    static func scatter(_ cells: [AggregatesController.HeatmapCell]) -> String {
        let points = cells.compactMap { cell -> (lat: Double, lon: Double, count: Int, hash: String)? in
            guard let c = ExportRenderer.geohashCenter(cell.geohash6) else { return nil }
            return (c.lat, c.lon, cell.count, cell.geohash6)
        }
        guard !points.isEmpty else {
            return #"<p class="lede">Areas are published but their locations could not be drawn.</p>"#
        }

        let width = 640.0, height = 360.0, pad = 28.0
        let minLat = points.map(\.lat).min()!, maxLat = points.map(\.lat).max()!
        let minLon = points.map(\.lon).min()!, maxLon = points.map(\.lon).max()!
        // Pad degenerate extents so a single cell still gets a visible plot.
        let latSpan = max(maxLat - minLat, 0.02), lonSpan = max(maxLon - minLon, 0.02)
        let maxCount = Double(points.map(\.count).max() ?? 1)

        func x(_ lon: Double) -> Double { pad + (lon - minLon) / lonSpan * (width - 2 * pad) }
        func y(_ lat: Double) -> Double { height - pad - (lat - minLat) / latSpan * (height - 2 * pad) }

        let gridLines = (1...3).map { i -> String in
            let gx = pad + Double(i) * (width - 2 * pad) / 4
            let gy = pad + Double(i) * (height - 2 * pad) / 4
            return "<line x1=\"\(gx)\" y1=\"\(pad)\" x2=\"\(gx)\" y2=\"\(height - pad)\"/>"
                + "<line x1=\"\(pad)\" y1=\"\(gy)\" x2=\"\(width - pad)\" y2=\"\(gy)\"/>"
        }.joined()

        let dots = points.map { p -> String in
            let r = 6 + 16 * sqrt(Double(p.count) / maxCount)
            return "<circle class=\"dot\" cx=\"\(fmt(x(p.lon)))\" cy=\"\(fmt(y(p.lat)))\" r=\"\(fmt(r))\">"
                + "<title>\(escape(p.hash)): \(p.count) sightings</title></circle>"
        }.joined()

        return """
        <svg viewBox="0 0 \(Int(width)) \(Int(height))" role="img" aria-label="Scatter of \(points.count) published areas, sized by sighting count">
          <g class="grid">\(gridLines)</g>
          \(dots)
        </svg>
        <p class="lede">Dot size is proportional to the square root of the sighting count. Positions are cell centres, not exact locations.</p>
        """
    }

    /// Bars per UTC day. Days are sorted chronologically, so the reader sees
    /// the trend without needing to scan the table.
    static func timeline(_ days: [AggregatesController.TimelineDay]) -> String {
        guard !days.isEmpty else {
            return #"<p class="lede">No day reached the publication threshold.</p>"#
        }
        let sorted = days.sorted { $0.date < $1.date }
        let width = 640.0, height = 200.0, pad = 28.0
        let maxCount = Double(sorted.map(\.count).max() ?? 1)
        let slot = (width - 2 * pad) / Double(sorted.count)
        let barWidth = max(2, slot * 0.7)

        let bars = sorted.enumerated().map { i, d -> String in
            let h = Double(d.count) / maxCount * (height - 2 * pad)
            let bx = pad + Double(i) * slot + (slot - barWidth) / 2
            let by = height - pad - h
            return "<rect class=\"bar\" x=\"\(fmt(bx))\" y=\"\(fmt(by))\" width=\"\(fmt(barWidth))\" height=\"\(fmt(h))\">"
                + "<title>\(escape(d.date)): \(d.count)</title></rect>"
        }.joined()

        let first = sorted.first!.date, last = sorted.last!.date
        return """
        <svg viewBox="0 0 \(Int(width)) \(Int(height))" role="img" aria-label="Bar chart of sightings per day, \(sorted.count) days shown">
          \(bars)
          <text class="axis" x="\(pad)" y="\(height - 8)">\(escape(first))</text>
          <text class="axis" x="\(width - pad)" y="\(height - 8)" text-anchor="end">\(escape(last))</text>
        </svg>
        """
    }

    // MARK: - Helpers

    private static func day(_ date: Date) -> String {
        AggregatesController.dayFormatter.string(from: date)
    }

    private static func fmt(_ v: Double) -> String {
        String(format: "%.1f", v)
    }

    static func escape(_ s: String) -> String {
        ModeratorController.escape(s)
    }
}
