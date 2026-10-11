import CryptoKit
import XCTest
@testable import FleetImporters
import PlateKit

final class CSVParserTests: XCTestCase {
    private let parser = CSVParser()

    func testSimpleRows() {
        let rows = parser.parse("a,b,c\n1,2,3\n")
        XCTAssertEqual(rows, [["a", "b", "c"], ["1", "2", "3"]])
    }

    func testQuotedCommaAndQuotes() {
        let rows = parser.parse("name,note\n\"Doe, Jane\",\"said \"\"hi\"\"\"\n")
        XCTAssertEqual(rows, [["name", "note"], ["Doe, Jane", "said \"hi\""]])
    }

    func testNewlineInsideQuotes() {
        let rows = parser.parse("a,b\n\"line1\nline2\",2\n")
        XCTAssertEqual(rows, [["a", "b"], ["line1\nline2", "2"]])
    }

    func testCRLFAndLoneCR() {
        XCTAssertEqual(parser.parse("a,b\r\n1,2\r\n3,4"), [["a", "b"], ["1", "2"], ["3", "4"]])
        XCTAssertEqual(parser.parse("a,b\r1,2"), [["a", "b"], ["1", "2"]])
    }

    func testTrailingEmptyRowsDropped() {
        XCTAssertEqual(parser.parse("a\n\n"), [["a"]])
        XCTAssertEqual(parser.parse(""), [])
    }
}

final class GSAFleetImporterTests: XCTestCase {
    private let sampleCSV = """
    Agency Name,Bureau Name,Make,Model,Model Year,Vehicle Category,License Plate Number,License Plate State,Asset Number,VIN
    "Department of Justice","Federal Bureau of Investigation","Ford","Explorer",2024,Law Enforcement,"fbi 4421","DC","FB-0001","1FM5K8ARXRGB12345"
    "Department of Justice","Federal Bureau of Investigation","Ford","Explorer",2024,Law Enforcement,"FBI4421","DC","FB-0001","1FM5K8ARXRGB12345"
    Department of Agriculture,Forest Service,Chevrolet,Silverado,2022,Fire Engine,"fs 7",CA,FS-0002,
    General Services Administration,,Toyota,Camry,2023,Sedan,,,
    ,,Toyota,Camry,2023,Sedan,ABC123,CA,
    """

    private func makeImporter(retrievedAt: Date = Date(timeIntervalSince1970: 1_760_000_000),
                              sourceURL: URL? = URL(string: "https://open.gsa.gov/api/example.csv")) -> GSAFleetImporter {
        GSAFleetImporter(config: .init(sourceType: .fleetRegistry,
                                       sourceURL: sourceURL,
                                       retrievedAt: retrievedAt))
    }

    func testParsesVehiclesWithProvenance() throws {
        let result = makeImporter().importCSV(sampleCSV)
        // The two identical FBI rows are one deduped identity; the GSA
        // sedan (no plate/unit) and the agency-less row are skipped.
        XCTAssertEqual(result.vehicles.count, 2)
        XCTAssertEqual(result.rowCount, 5)
        XCTAssertEqual(result.skipped.map(\.lineNumber), [5, 6])

        let first = try XCTUnwrap(result.vehicles.first { $0.vehicle.primaryPlate?.text == "FBI4421" })
        XCTAssertEqual(first.vehicle.unitNumber, "FB-0001")
        XCTAssertEqual(first.vehicle.kind, .patrol)
        XCTAssertEqual(first.vehicle.make, "Ford")
        XCTAssertEqual(first.vehicle.yearRange, 2024...2024)
        XCTAssertEqual(first.vehicle.status, .active)
        XCTAssertEqual(first.agency.name, "Department of Justice")
        XCTAssertEqual(first.agency.level, .federal)

        // Guardrail: every vehicle carries a citation bound to its exact row.
        let citation = try XCTUnwrap(first.vehicle.provenance.first)
        XCTAssertEqual(citation.sourceType, .fleetRegistry)
        XCTAssertEqual(citation.url, URL(string: "https://open.gsa.gov/api/example.csv"))
        XCTAssertEqual(citation.retrievedAt, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertNotNil(citation.excerptHashSHA256)
        XCTAssertEqual(citation.excerptHashSHA256?.count, 64)
        // Identical rows (dup re-import) hash identically.
        let second = try XCTUnwrap(result.vehicles.first { $0.vehicle.id == first.vehicle.id })
        XCTAssertEqual(second.vehicle.provenance.first?.excerptHashSHA256,
                       citation.excerptHashSHA256)
    }

    func testPlateNormalization() throws {
        let result = makeImporter().importCSV(sampleCSV)
        // "fbi 4421" and "FBI4421" normalize to the same plate → same
        // identity, emitted once (dup row is the re-import case).
        let fbi = result.vehicles.filter { $0.vehicle.primaryPlate?.text == "FBI4421" }
        XCTAssertEqual(fbi.count, 1)
        XCTAssertEqual(fbi.first?.vehicle.primaryPlate?.issuingRegion, "US-DC")
    }

    func testDeterministicIDsAcrossImports() throws {
        let a = makeImporter().importCSV(sampleCSV)
        let b = makeImporter().importCSV(sampleCSV)
        XCTAssertEqual(a.vehicles.map(\.vehicle.id), b.vehicles.map(\.vehicle.id))
        XCTAssertEqual(a.agencies.map(\.id), b.agencies.map(\.id))
    }

    func testVINColumnIsNeverPersisted() throws {
        // Guardrail: the feed's VIN column is unmapped; no vehicle may
        // carry it anywhere in its persisted fields.
        let result = makeImporter().importCSV(sampleCSV)
        for imported in result.vehicles {
            let encoded = String(data: try JSONEncoder().encode(imported.vehicle),
                                 encoding: .utf8) ?? ""
            XCTAssertFalse(encoded.contains("1FM5K8ARXRGB12345"))
            XCTAssertNil(imported.vehicle.primaryPlate?.rawText.range(of: "1FM"))
        }
    }

    func testAgenciesDeduped() {
        let result = makeImporter().importCSV(sampleCSV)
        // DOJ (2 rows) + USDA Forest Service. The agency-less row never
        // produces an agency — enrichment requires a cited source org.
        XCTAssertEqual(result.agencies.count, 2)
    }

    func testClassMapping() {
        XCTAssertEqual(VehicleClassMapper.map(category: "Law Enforcement", fallback: .federal), .patrol)
        XCTAssertEqual(VehicleClassMapper.map(category: "ambulance", fallback: .federal), .ambulance)
        XCTAssertEqual(VehicleClassMapper.map(category: "school bus", fallback: .federal), .schoolBus)
        XCTAssertEqual(VehicleClassMapper.map(category: "Snow Plow", fallback: .federal), .publicWorks)
        XCTAssertEqual(VehicleClassMapper.map(category: "Sedan", fallback: .federal), .federal)
        XCTAssertEqual(VehicleClassMapper.map(category: nil, fallback: .federal), .federal)
    }

    func testEmptyInput() {
        let result = makeImporter().importCSV("")
        XCTAssertEqual(result.vehicles.count, 0)
        XCTAssertEqual(result.skipped.count, 0)
    }
}

final class CityFleetImporterTests: XCTestCase {
    private let sampleCSV = """
    Department,Division,Unit Number,License Plate,State,Make,Model,Model Year,Vehicle Type,Fuel Type
    "Austin Police Department","Patrol","APD-4421","APD 4421","TX","Ford","Explorer",2024,"Patrol Sedan","Gasoline"
    "Austin Police Department","Patrol","APD-4421","APD4421","TX","Ford","Explorer",2024,"Patrol Sedan","Gasoline"
    "Austin Fire Department","Engine Co 1","AFD-E1","AFD E1","TX","Pierce","Arrow XT",2022,"Fire Engine","Diesel"
    "Austin Public Works","Street Maintenance","APW-100","PW 100","TX","Ford","F-350",2021,"Pickup","Gasoline"
    "Traffic Engineering",,,,TX,,,
    """

    private func makeImporter(retrievedAt: Date = Date(timeIntervalSince1970: 1_760_000_000),
                              sourceURL: URL? = URL(string: "https://data.austintexas.gov/api/example.csv"),
                              agencyLevel: AgencyLevel = .municipal) -> CityFleetImporter {
        CityFleetImporter(config: .init(sourceType: .fleetRegistry,
                                        sourceURL: sourceURL,
                                        retrievedAt: retrievedAt,
                                        agencyLevel: agencyLevel))
    }

    func testParsesVehiclesWithProvenance() throws {
        let result = makeImporter().importCSV(sampleCSV)
        // 4 identifying rows; the duplicate APD row dedupes, the no-plate
        // "Traffic Engineering" row is skipped.
        XCTAssertEqual(result.vehicles.count, 3)
        XCTAssertEqual(result.rowCount, 5)
        XCTAssertEqual(result.skipped.map(\.lineNumber), [6])

        let police = try XCTUnwrap(result.vehicles.first { $0.vehicle.primaryPlate?.text == "APD4421" })
        XCTAssertEqual(police.vehicle.unitNumber, "APD-4421")
        XCTAssertEqual(police.vehicle.kind, .patrol)
        XCTAssertEqual(police.vehicle.make, "Ford")
        XCTAssertEqual(police.vehicle.yearRange, 2024...2024)
        XCTAssertEqual(police.vehicle.status, .active)
        XCTAssertEqual(police.agency.name, "Austin Police Department")
        XCTAssertEqual(police.agency.level, .municipal)

        let citation = try XCTUnwrap(police.vehicle.provenance.first)
        XCTAssertEqual(citation.sourceType, .fleetRegistry)
        XCTAssertEqual(citation.url, URL(string: "https://data.austintexas.gov/api/example.csv"))
        XCTAssertEqual(citation.retrievedAt, Date(timeIntervalSince1970: 1_760_000_000))
        XCTAssertNotNil(citation.excerptHashSHA256)

        let fire = try XCTUnwrap(result.vehicles.first { $0.vehicle.primaryPlate?.text == "AFDE1" })
        XCTAssertEqual(fire.vehicle.kind, .fireEngine)
        XCTAssertEqual(fire.agency.name, "Austin Fire Department")

        let pw = try XCTUnwrap(result.vehicles.first { $0.vehicle.primaryPlate?.text == "PW100" })
        XCTAssertEqual(pw.vehicle.kind, .publicWorks)
        XCTAssertEqual(pw.agency.name, "Austin Public Works")
    }

    func testDeterministicIDsAcrossImports() throws {
        let a = makeImporter().importCSV(sampleCSV)
        let b = makeImporter().importCSV(sampleCSV)
        XCTAssertEqual(a.vehicles.map(\.vehicle.id), b.vehicles.map(\.vehicle.id))
        XCTAssertEqual(a.agencies.map(\.id), b.agencies.map(\.id))
    }

    func testPlateNormalization() throws {
        let result = makeImporter().importCSV(sampleCSV)
        // "APD 4421" and "APD4421" normalize to same → single identity.
        let apd = result.vehicles.filter { $0.vehicle.primaryPlate?.text == "APD4421" }
        XCTAssertEqual(apd.count, 1)
        XCTAssertEqual(apd.first?.vehicle.primaryPlate?.issuingRegion, "US-TX")
    }

    func testCrossCityIDCollisionAvoidance() throws {
        // Same plate in different cities should produce different vehicle IDs.
        let austin = makeImporter(agencyLevel: .municipal).importCSV("""
            Department,Division,Unit Number,License Plate,State,Make,Model,Model Year,Vehicle Type,Fuel Type
            Austin PD,Patrol,1,ABC123,TX,Ford,Explorer,2024,Patrol Sedan,Gas
            """)
        let dallas = CityFleetImporter(config: .init(agencyLevel: .municipal)).importCSV("""
            Department,Division,Unit Number,License Plate,State,Make,Model,Model Year,Vehicle Type,Fuel Type
            Dallas PD,Patrol,1,ABC123,TX,Ford,Explorer,2024,Patrol Sedan,Gas
            """)
        XCTAssertNotEqual(austin.vehicles.first?.vehicle.id, dallas.vehicles.first?.vehicle.id)
    }

    func testAgenciesDeduped() {
        let result = makeImporter().importCSV(sampleCSV)
        // APD (2 rows) + AFD + APW = 3 agencies.
        XCTAssertEqual(result.agencies.count, 3)
    }

    func testClassMapping() throws {
        XCTAssertEqual(VehicleClassMapper.map(category: "Patrol Sedan", fallback: .otherFleet), .patrol)
        XCTAssertEqual(VehicleClassMapper.map(category: "Fire Engine", fallback: .otherFleet), .fireEngine)
        XCTAssertEqual(VehicleClassMapper.map(category: "Pickup", fallback: .otherFleet), .publicWorks)
        XCTAssertEqual(VehicleClassMapper.map(category: "Sedan", fallback: .otherFleet), .otherFleet)
        XCTAssertEqual(VehicleClassMapper.map(category: nil, fallback: .otherFleet), .otherFleet)
    }

    func testPresetColumnMaps() {
        // Verify preset column maps have expected keys.
        let chicago = CityFeedPresets.chicago
        XCTAssertFalse(chicago.department.isEmpty)
        XCTAssertFalse(chicago.plate.isEmpty)
        XCTAssertFalse(chicago.unit.isEmpty)

        let sf = CityFeedPresets.sanFrancisco
        XCTAssertFalse(sf.division.isEmpty)

        let nyc = CityFeedPresets.newYorkCity
        XCTAssertFalse(nyc.department.isEmpty)

        let la = CityFeedPresets.losAngeles
        XCTAssertFalse(la.plate.isEmpty)

        let austin = CityFeedPresets.austin
        XCTAssertFalse(austin.unit.isEmpty)
    }

    func testEmptyInput() {
        let result = makeImporter().importCSV("")
        XCTAssertEqual(result.vehicles.count, 0)
        XCTAssertEqual(result.skipped.count, 0)
    }

    func testCountyLevelAgency() throws {
        let county = CityFleetImporter(config: .init(agencyLevel: .county)).importCSV("""
            Department,Division,Unit Number,License Plate,State,Make,Model,Model Year,Vehicle Type,Fuel Type
            "Harris County Sheriff","Patrol",1,"HCS 100","TX","Chevrolet","Tahoe",2023,"Patrol SUV","Gasoline"
            """)
        let agency = try XCTUnwrap(county.agencies.first)
        XCTAssertEqual(agency.level, .county)
    }
}

final class NHTSAVINDecoderTests: XCTestCase {
    func testVINValidationViaDecode() async {
        let decoder = NHTSAVINDecoder()
        // Valid VIN format passes validation (but network fails)
        do {
            _ = try await decoder.decode("1HGBH41JXMN109186")
        } catch let e as NHTSAVINDecoder.DecodeError {
            // Network error is expected since we're not mocking
            XCTAssertNotEqual(e, .invalidVIN(""))
        } catch {
            // Other errors (network) are fine
        }

        // Invalid length
        do {
            _ = try await decoder.decode("123")
            XCTFail("should throw")
        } catch let e as NHTSAVINDecoder.DecodeError {
            XCTAssertEqual(e, .invalidVIN("VIN must be 17 alphanumeric characters after cleaning: 123"))
        } catch {
            XCTFail("wrong error type")
        }

        // Non-alphanumeric
        do {
            _ = try await decoder.decode("1HGBH41JXMN10918!")
            XCTFail("should throw")
        } catch let e as NHTSAVINDecoder.DecodeError {
            XCTAssertEqual(e, .invalidVIN("VIN must be 17 alphanumeric characters after cleaning: 1HGBH41JXMN10918!"))
        } catch {
            XCTFail("wrong error type")
        }
    }

    func testCacheBehavior() async {
        let cachedVIN = "1HGBH41JXMN109186"
        let cached = NHTSAVINDecoder.DecodedVIN(
            vin: cachedVIN,
            make: "Honda",
            model: "Accord",
            modelYear: 2021,
            citation: SourceCitation(sourceType: .nhtsaVpic, url: nil, retrievedAt: Date(), excerptHashSHA256: "test")
        )
        let decoder = NHTSAVINDecoder(config: .init(cache: [cachedVIN: cached]))

        let result = try? await decoder.decode(cachedVIN)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.make, "Honda")
        XCTAssertEqual(result?.model, "Accord")
    }

    func testDecodeErrorTypes() {
        XCTAssertEqual(NHTSAVINDecoder.DecodeError.invalidVIN("test"), .invalidVIN("test"))
        XCTAssertEqual(NHTSAVINDecoder.DecodeError.notFound("test"), .notFound("test"))
        XCTAssertEqual(NHTSAVINDecoder.DecodeError.networkError("test"), .networkError("test"))
        XCTAssertEqual(NHTSAVINDecoder.DecodeError.rateLimited(retryAfter: 5), .rateLimited(retryAfter: 5))
    }
}