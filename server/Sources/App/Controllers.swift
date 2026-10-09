import Fluent
import Vapor

/// GET /v1/vehicles?plate=… — public plate lookup (fleet records only).
struct VehiclesController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let vehicles = routes.grouped("v1", "vehicles")
        vehicles.get(use: search)
    }

    @Sendable
    func search(req: Request) async throws -> [PublicVehicleDTO] {
        let plate = try req.query.get(String.self, at: "plate")
            .uppercased()
            .filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
        let rows = try await Vehicle.query(on: req.db)
            .filter(\.$plateText == plate)
            .with(\.$agency)
            .all()
        return rows.compactMap { v in
            guard let id = v.id else { return nil }
            return PublicVehicleDTO(
                id: id, plateText: v.plateText, unitNumber: v.unitNumber,
                agencyName: v.$agency.value??.name, kind: v.kind,
                make: v.make, model: v.model, status: v.status,
                sightingsCount: v.sightingsCount)
        }
    }
}

/// GET /v1/agencies — public agency directory.
struct AgenciesController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1", "agencies").get(use: list)
    }

    @Sendable
    func list(req: Request) async throws -> [AgencyDTO] {
        try await Agency.query(on: req.db).all().compactMap { a in
            guard let id = a.id else { return nil }
            return AgencyDTO(id: id, name: a.name, shortName: a.shortName,
                             level: a.level,
                             parentAgencyID: a.$parentAgency.id,
                             publicContactURL: a.publicContactURL)
        }
    }
}

/// GET /v1/stats — transparency metrics for dashboards.
struct StatsController: RouteCollection {
    struct FleetStats: Content {
        var totalVehicles: Int
        var totalAgencies: Int
        var totalSightings: Int
        var fleetConfirmedSightings: Int
    }

    func boot(routes: any RoutesBuilder) throws {
        routes.grouped("v1", "stats").get(use: summary)
    }

    @Sendable
    func summary(req: Request) async throws -> FleetStats {
        async let vehicles = Vehicle.query(on: req.db).count()
        async let agencies = Agency.query(on: req.db).count()
        async let sightings = Sighting.query(on: req.db).count()
        async let confirmed = Sighting.query(on: req.db)
            .filter(\.$moderationState == "fleetConfirmed").count()
        return try await FleetStats(totalVehicles: vehicles,
                                    totalAgencies: agencies,
                                    totalSightings: sightings,
                                    fleetConfirmedSightings: confirmed)
    }
}
