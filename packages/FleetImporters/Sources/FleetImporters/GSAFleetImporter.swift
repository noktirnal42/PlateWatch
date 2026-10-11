import CryptoKit
import Foundation
import PlateKit

/// Stable, content-derived UUIDs so a re-import of the same public records
/// produces the same vehicle IDs (idempotent ingestion, no duplicate fleet
/// rows). Version/variant bits are set so the result is a valid RFC 4122
/// name-based-style UUID.
public enum StableID {
    public static func uuid(namespace: String, _ components: String...) -> UUID {
        var data = Data(namespace.utf8)
        data.append(0)
        for c in components {
            data.append(contentsOf: c.lowercased().utf8)
            data.append(0)
        }
        let digest = SHA256.hash(data: data)
        var bytes = [UInt8](digest.prefix(16))
        bytes[6] = (bytes[6] & 0x0F) | 0x50
        bytes[8] = (bytes[8] & 0x3F) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5],
                           bytes[6], bytes[7], bytes[8], bytes[9], bytes[10], bytes[11],
                           bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    public static func sha256Hex(_ value: some StringProtocol) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// GSA Federal Fleet Report–style public CSV → `Vehicle` + `SourceCitation`.
///
/// Guardrails encoded here (docs/LEGAL-ETHICS.md):
/// - Every emitted vehicle carries a citation bound to the exact source row
///   (SHA-256 excerpt hash + retrieval URL + date). Provenance everywhere.
/// - The importer ingests **public records only**; nothing is stored beyond
///   the fields in `docs/DATA-MODEL.md` — VIN-like identifier columns in the
///   feed are deliberately unmapped and never persisted (they only exist to
///   be hashed away upstream; here they are simply ignored).
/// - No officer/subject names are read; roster enrichment is a different,
///   separately-cited importer.
public struct GSAFleetImporter: Sendable {

    /// Logical field → accepted header spellings (case-insensitive, exact
    /// match after whitespace collapse). Configurable because GSA and city
    /// open-data feeds re-name columns between releases.
    public struct ColumnMap: Sendable {
        public var agency: Set<String>
        public var bureau: Set<String>
        public var unit: Set<String>
        public var plate: Set<String>
        public var plateState: Set<String>
        public var make: Set<String>
        public var model: Set<String>
        public var modelYear: Set<String>
        public var category: Set<String>

        public init(agency: Set<String> = ["agency name", "agency"],
                    bureau: Set<String> = ["bureau name", "bureau"],
                    unit: Set<String> = ["asset number", "tag number", "unit number", "unit"],
                    plate: Set<String> = ["license plate number", "license plate", "plate number", "plate"],
                    plateState: Set<String> = ["license plate state", "plate state", "state"],
                    make: Set<String> = ["make"],
                    model: Set<String> = ["model"],
                    modelYear: Set<String> = ["model year", "year"],
                    category: Set<String> = ["vehicle category", "vehicle type", "category"]) {
            self.agency = agency; self.bureau = bureau; self.unit = unit
            self.plate = plate; self.plateState = plateState; self.make = make
            self.model = model; self.modelYear = modelYear; self.category = category
        }

        public static let `default` = ColumnMap()
    }

    public struct Config: Sendable {
        public var sourceType: SourceCitation.SourceType
        /// The public dataset URL recorded in every citation.
        public var sourceURL: URL?
        public var retrievedAt: Date
        public var columns: ColumnMap

        public init(sourceType: SourceCitation.SourceType = .fleetRegistry,
                    sourceURL: URL? = nil,
                    retrievedAt: Date = Date(),
                    columns: ColumnMap = .default) {
            self.sourceType = sourceType; self.sourceURL = sourceURL
            self.retrievedAt = retrievedAt; self.columns = columns
        }
    }

    public struct SkippedRow: Sendable, Equatable {
        public var lineNumber: Int
        public var reason: String
    }

    public struct ImportedVehicle: Sendable {
        public var vehicle: Vehicle
        public var agency: Agency
    }

    public struct Result: Sendable {
        public var vehicles: [ImportedVehicle]
        public var agencies: [Agency]
        public var skipped: [SkippedRow]
        public var rowCount: Int
    }

    private let config: Config
    private let parser = CSVParser()

    public init(config: Config = Config()) {
        self.config = config
    }

    public func importCSV(_ text: String) -> Result {
        let rows = parser.parse(text)
        guard let header = rows.first else {
            return Result(vehicles: [], agencies: [], skipped: [], rowCount: 0)
        }
        let index = columnIndex(header: header)
        var vehiclesByID: [UUID: ImportedVehicle] = [:]
        var agenciesByID: [UUID: Agency] = [:]
        var skipped: [SkippedRow] = []

        for (offset, row) in rows.dropFirst().enumerated() {
            let lineNumber = offset + 2 // 1-based, header consumed
            let rawRow = row.joined(separator: ",")
            let excerpt = StableID.sha256Hex(rawRow)

            guard let agencyName = value(row, index.agency) ?? value(row, index.bureau),
                  !agencyName.isEmpty else {
                skipped.append(SkippedRow(lineNumber: lineNumber,
                                          reason: "no agency — enrichment requires a cited source org"))
                continue
            }

            let plateRaw = value(row, index.plate)
            let unitRaw = value(row, index.unit)
            let make = value(row, index.make)
            let model = value(row, index.model)
            let plateText = plateRaw.map { Plate.normalize($0) } ?? ""
            let unitNumber = unitRaw?.trimmingCharacters(in: .whitespaces)

            guard !plateText.isEmpty || !(unitNumber ?? "").isEmpty else {
                skipped.append(SkippedRow(lineNumber: lineNumber,
                                          reason: "no plate and no unit number — nothing identifying"))
                continue
            }

            let agencyID = StableID.uuid(namespace: "platewatch-agency", agencyName)
            let agency = agenciesByID[agencyID] ?? Agency(
                id: agencyID,
                name: agencyName,
                level: .federal, // GSA fleet inventory is federal records
                parentAgencyID: nil)
            agenciesByID[agencyID] = agency

            let vehicleID = StableID.uuid(namespace: "platewatch-vehicle-gsa",
                                          agencyName, unitNumber ?? "", plateText)
            let citation = SourceCitation(
                sourceType: config.sourceType,
                url: config.sourceURL,
                retrievedAt: config.retrievedAt,
                excerptHashSHA256: excerpt)

            let vehicle = Vehicle(
                id: vehicleID,
                primaryPlate: plateText.isEmpty ? nil
                    : Plate(text: plateRaw ?? plateText,
                            issuingRegion: normalizedState(value(row, index.plateState)),
                            country: "US"),
                unitNumber: unitNumber,
                agencyID: agencyID,
                kind: VehicleClassMapper.map(category: value(row, index.category),
                                             fallback: .federal),
                make: make,
                model: model,
                yearRange: modelYearRange(value(row, index.modelYear)),
                colors: [],
                status: .active,
                provenance: [citation])

            // Re-import: same identity, provenance refreshed (latest
            // retrieval date + excerpt hash win).
            vehiclesByID[vehicleID] = ImportedVehicle(vehicle: vehicle, agency: agency)
        }

        let vehicles = vehiclesByID.values.sorted { $0.vehicle.id.uuidString < $1.vehicle.id.uuidString }
        let agencies = agenciesByID.values.sorted { $0.id.uuidString < $1.id.uuidString }
        return Result(vehicles: vehicles, agencies: agencies,
                      skipped: skipped, rowCount: rows.count - 1)
    }

    // MARK: - Header mapping

    private struct FieldIndexes {
        var agency: Int?
        var bureau: Int?
        var unit: Int?
        var plate: Int?
        var plateState: Int?
        var make: Int?
        var model: Int?
        var modelYear: Int?
        var category: Int?
    }

    private func columnIndex(header: [String]) -> FieldIndexes {
        func find(_ aliases: Set<String>) -> Int? {
            header.firstIndex { aliases.contains(canonical($0)) }
        }
        return FieldIndexes(
            agency: find(config.columns.agency),
            bureau: find(config.columns.bureau),
            unit: find(config.columns.unit),
            plate: find(config.columns.plate),
            plateState: find(config.columns.plateState),
            make: find(config.columns.make),
            model: find(config.columns.model),
            modelYear: find(config.columns.modelYear),
            category: find(config.columns.category))
    }

    private func canonical(_ header: String) -> String {
        header.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func value(_ row: [String], _ index: Int?) -> String? {
        guard let index, index < row.count else { return nil }
        let v = row[index].trimmingCharacters(in: .whitespaces)
        return v.isEmpty ? nil : v
    }

    /// "CA" / "California"-style feed values → ISO 3166-2 where the feed
    /// already carries the two-letter code; anything else passed through.
    private func normalizedState(_ raw: String?) -> String? {
        guard let raw, raw.count == 2 else { return raw }
        return "US-\(raw.uppercased())"
    }

    private func modelYearRange(_ raw: String?) -> ClosedRange<Int>? {
        guard let raw, let year = Int(raw.filter(\.isNumber)), (1900...2100).contains(year) else {
            return nil
        }
        return year...year
    }
}

/// GSA/city feed category text → `VehicleClass`. Unknown categories fall
/// back to the feed's fleet-wide class rather than `.unknown`, because the
/// row's provenance establishes fleet membership even when the class text
/// is unrecognized.
public enum VehicleClassMapper {
    public static func map(category: String?, fallback: VehicleClass) -> VehicleClass {
        guard let category else { return fallback }
        let c = category.lowercased()
        if c.contains("law enforcement") || c.contains("police") { return .patrol }
        if c.contains("ambulance") || c.contains("ems") { return .ambulance }
        if c.contains("fire") { return .fireEngine }
        if c.contains("school bus") { return .schoolBus }
        if c.contains("bus") || c.contains("transit") { return .transit }
        if c.contains("street sweeper") || c.contains("snow") || c.contains("public works")
            || c.contains("maintenance") || c.contains("utility") { return .publicWorks }
        if c.contains("military") { return .military }
        if c.contains("park") || c.contains("ranger") { return .parkRanger }
        if c.contains("highway") { return .highway }
        return fallback
    }
}
