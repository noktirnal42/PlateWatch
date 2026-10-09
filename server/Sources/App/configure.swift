import Fluent
import FluentPostgresDriver
import Vapor

/// App wiring: database, migrations, routes. Nothing else lives here —
/// behavior is in Controllers/ and Services/.
func configure(_ app: Application) async throws {
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
    if app.environment != .testing {
        try await app.autoMigrate()
    }

    try app.register(collection: SightingsController())
    try app.register(collection: VehiclesController())
    try app.register(collection: AgenciesController())
    try app.register(collection: StatsController())
    try app.register(collection: ExportController())

    app.get("health") { _ in ["status": "ok"] }
}
