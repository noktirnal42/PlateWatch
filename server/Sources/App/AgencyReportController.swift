import Fluent
import Vapor

/// Agency report card (M4): fleet size, sightings density, public links.
/// Read-only, sourced entirely from imported public records — the card
/// summarizes what the dataset already says, never individual movement.
struct AgencyReportController: RouteCollection {

    struct Report: Content {
        var agency: AgencyDTO
        var fleetSize: Int
        var sightings30d: Int
        var activeUnits: Int
        var publicContactURL: String?
        var budgetURL: String?
        var generatedAt: Date
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1", "agencies").get(":agencyID", "report", use: json)
        routes.get("agencies", ":agencyID", "report", use: page)
    }

    @Sendable
    func json(req: Request) async throws -> Report {
        try await Self.build(req)
    }

    @Sendable
    func page(req: Request) async throws -> Response {
        let report = try await Self.build(req)
        return Response(status: .ok,
                        headers: ["Content-Type": "text/html; charset=utf-8"],
                        body: .init(string: Self.render(report)))
    }

    // MARK: - Shared path

    static func build(_ req: Request) async throws -> Report {
        guard let id = req.parameters.get("agencyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "agencyID must be a UUID")
        }
        guard let agency = try await Agency.find(id, on: req.db) else {
            throw Abort(.notFound, reason: "agency not found")
        }

        let windowStart = Calendar(identifier: .gregorian)
            .date(byAdding: .day, value: -30, to: Date()) ?? Date().addingTimeInterval(-30 * 86_400)

        // Fleet roster for this agency. Unit numbers are the join key into
        // sightings (roster matching), vehicles give the fleet size.
        let assignments = try await UnitAssignment.query(on: req.db)
            .filter(\.$agency.$id == id)
            .all()
        let unitNumbers = Set(assignments.map(\.unitNumber))

        async let fleetSize = Vehicle.query(on: req.db)
            .filter(\.$agency.$id == id)
            .count()
        async let sightingRows = Sighting.query(on: req.db)
            .filter(\.$moderationState == "fleetConfirmed")
            .filter(\.$capturedAt >= windowStart)
            .all()

        return Report(
            agency: AgencyDTO(id: id, name: agency.name, shortName: agency.shortName,
                              level: agency.level,
                              parentAgencyID: agency.$parentAgency.id,
                              publicContactURL: agency.publicContactURL),
            fleetSize: try await fleetSize,
            sightings30d: try await sightingRows.filter { row in
                // Linked either by vehicle ownership or roster unit match.
                if row.vehicle?.$agency.id == id { return true }
                if let unit = row.unitNumber { return unitNumbers.contains(unit) }
                return false
            }.count,
            activeUnits: unitNumbers.count,
            publicContactURL: agency.publicContactURL,
            budgetURL: agency.budgetURL,
            generatedAt: Date())
    }

    // MARK: - Server-rendered HTML (no client JS, no tracking)

    static func render(_ report: Report) -> String {
        func esc(_ s: String?) -> String {
            s?.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
                .replacingOccurrences(of: "\"", with: "&quot;")
                .replacingOccurrences(of: "'", with: "&#39;") ?? ""
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        let generated = formatter.string(from: report.generatedAt)

        var contact = ""
        if let url = report.publicContactURL, let parsed = URL(string: url) {
            contact = "<a href=\"\(esc(url))\">\(esc(parsed.host ?? url))</a>"
        } else {
            contact = "<em>not published</em>"
        }
        var budget = ""
        if let url = report.budgetURL, let parsed = URL(string: url) {
            budget = "<a href=\"\(esc(url))\">\(esc(parsed.host ?? url))</a>"
        } else {
            budget = "<em>add via agency record (budget_url)</em>"
        }

        return """
        <!DOCTYPE html>
        <html lang="en">
        <head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(esc(report.agency.name)) — Fleet Report Card</title>
        <style>
          body { font-family: -apple-system, system-ui, sans-serif; margin: 2rem auto; max-width: 42rem; padding: 0 1rem; color: #111; }
          h1 { font-size: 1.4rem; }
          .grid { display: grid; grid-template-columns: repeat(3, 1fr); gap: 1rem; margin: 1.5rem 0; }
          .stat { border: 1px solid #ddd; border-radius: 10px; padding: 1rem; text-align: center; }
          .stat .n { font-size: 2rem; font-weight: 700; }
          .stat .l { color: #666; font-size: .85rem; }
          footer { color: #777; font-size: .8rem; margin-top: 2rem; }
        </style></head>
        <body>
          <h1>\(esc(report.agency.name))</h1>
          <p>Level: \(esc(report.agency.level)) · Fleet accountability report card</p>
          <div class="grid">
            <div class="stat"><div class="n">\(report.fleetSize)</div><div class="l">known fleet vehicles</div></div>
            <div class="stat"><div class="n">\(report.sightings30d)</div><div class="l">fleet-confirmed sightings (30 d)</div></div>
            <div class="stat"><div class="n">\(report.activeUnits)</div><div class="l">rostered unit numbers</div></div>
          </div>
          <p>Public contact: \(contact)<br>Budget: \(budget)</p>
          <footer>Generated \(generated) from public records only. Aggregated counts; no individual movement.</footer>
        </body></html>
        """
    }
}
