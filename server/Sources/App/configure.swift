import Fluent
import FluentPostgresDriver
import Vapor

/// App wiring: database, migrations, routes. Nothing else lives here —
/// behavior is in Controllers/ and Services/.
func configure(_ app: Application) async throws {
    // Port 8083 by default: 8080 is commonly taken by a local Apache, and
    // 8081/8082 by mitmproxy. Override with PORT / HOST for deployments.
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8083
    app.http.server.configuration.hostname = Environment.get("HOST") ?? "127.0.0.1"

    if app.environment == .testing {
        // Tests boot without a database; add in-memory SQLite here later if
        // route tests need persistence.
    } else {
        // Local dev uses docker-compose (no TLS); production deployments set
        // DATABASE_URL with a TLS-requiring scheme (postgres://…?sslmode=require).
        let url = Environment.get("DATABASE_URL")
            ?? "postgres://platewatch:platewatch-dev-only@localhost:5432/platewatch"
        let config = try SQLPostgresConfiguration(url: url)
        app.databases.use(.postgres(configuration: config), as: .psql)
    }

    // Order matters: foreign keys. Agencies first, then vehicles, then the
    // tables that reference them. Caught by live QA (postgres 42P01).
    app.migrations.add(CreateAgencies())
    app.migrations.add(CreateVehicles())
    app.migrations.add(CreateUnitAssignments())
    app.migrations.add(CreateSightings())
    app.migrations.add(CreateDeviceReputations())
    app.migrations.add(AddSightingCreatedAt())
    app.migrations.add(AddAgencyBudgetURL())
    if app.environment != .testing {
        try await app.autoMigrate()
    }

    try app.register(collection: SightingsController())
    try app.register(collection: VehiclesController())
    try app.register(collection: AgenciesController())
    try app.register(collection: AgencyReportController())
    try app.register(collection: StatsController())
    try app.register(collection: ExportController())
    try app.register(collection: AggregatesController())
    try app.register(collection: ModeratorController(token: Environment.get("MODERATOR_TOKEN")))

    app.get("health") { _ in ["status": "ok"] }

    // Nightly public dataset export (M4). Not scheduled under test.
    if app.environment != .testing {
        app.lifecycle.use(NightlyExportJob())
    }
}
