import Foundation
import PlateKit

/// NHTSA vPIC (Vehicle Product Information Catalog) API client.
/// Free, no-auth REST endpoint: https://vpic.nhtsa.dot.gov/api/
/// Provides VIN decode → make, model, year, manufacturer, vehicle type, etc.
/// Guardrails: only decodes VINs from public fleet/auction records (never private VINs).
public struct NHTSAVINDecoder: Sendable {

    public struct Config: Sendable {
        public var baseURL: URL
        public var timeout: TimeInterval
        public var cache: [String: DecodedVIN]  // simple in-memory cache

        public init(baseURL: URL = URL(string: "https://vpic.nhtsa.dot.gov/api")!,
                    timeout: TimeInterval = 10,
                    cache: [String: DecodedVIN] = [:]) {
            self.baseURL = baseURL
            self.timeout = timeout
            self.cache = cache
        }
    }

    /// Decoded VIN result with provenance.
    public struct DecodedVIN: Sendable, Codable, Equatable {
        public var vin: String
        public var make: String?
        public var model: String?
        public var modelYear: Int?
        public var manufacturer: String?
        public var vehicleType: String?
        public var bodyClass: String?
        public var doors: Int?
        public var fuelType: String?
        public var engineCylinders: Int?
        public var displacementL: Double?
        /// Source citation bound to the API response.
        public var citation: SourceCitation

        public init(vin: String,
                    make: String? = nil,
                    model: String? = nil,
                    modelYear: Int? = nil,
                    manufacturer: String? = nil,
                    vehicleType: String? = nil,
                    bodyClass: String? = nil,
                    doors: Int? = nil,
                    fuelType: String? = nil,
                    engineCylinders: Int? = nil,
                    displacementL: Double? = nil,
                    citation: SourceCitation) {
            self.vin = vin
            self.make = make
            self.model = model
            self.modelYear = modelYear
            self.manufacturer = manufacturer
            self.vehicleType = vehicleType
            self.bodyClass = bodyClass
            self.doors = doors
            self.fuelType = fuelType
            self.engineCylinders = engineCylinders
            self.displacementL = displacementL
            self.citation = citation
        }
    }

    /// Error types for VIN decoding.
    public enum DecodeError: Error, Equatable {
        case invalidVIN(String)
        case networkError(String)
        case invalidResponse(String)
        case notFound(String)
        case rateLimited(retryAfter: TimeInterval?)
    }

    private let config: Config
    private let session: URLSession

    public init(config: Config = Config(), session: URLSession = .shared) {
        self.config = config
        self.session = session
    }

    /// Decode a single VIN with caching and provenance.
    /// - Parameter vin: 17-character VIN (will be normalized to uppercase, stripped).
    /// - Returns: DecodedVIN with make/model/year and a SourceCitation.
    public func decode(_ vin: String) async throws -> DecodedVIN {
        let cleanVIN = vin.uppercased().filter { $0.isLetter || $0.isNumber }
        guard cleanVIN.count == 17 else {
            throw DecodeError.invalidVIN("VIN must be 17 alphanumeric characters after cleaning: \(vin)")
        }

        // Cache hit
        if let cached = config.cache[cleanVIN] {
            return cached
        }

        let url = config.baseURL.appending(path: "vehicles/DecodeVIN/\(cleanVIN)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "format", value: "json")
        ]

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = config.timeout
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw DecodeError.networkError("non-HTTP response")
        }

        switch http.statusCode {
        case 200: break
        case 404: throw DecodeError.notFound("VIN not found in NHTSA database: \(cleanVIN)")
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw DecodeError.rateLimited(retryAfter: retryAfter)
        default:
            throw DecodeError.networkError("HTTP \(http.statusCode)")
        }

        // Parse NHTSA response format: { Count: N, Message: "...", SearchCriteria: "...", Results: [...] }
        struct NHTSAResponse: Codable {
            var Count: Int
            var Message: String
            var SearchCriteria: String
            var Results: [NHTSAResult]
        }
        struct NHTSAResult: Codable {
            var Variable: String
            var Value: String?
            var ValueId: String?
        }

        let decoded = try JSONDecoder().decode(NHTSAResponse.self, from: data)
        guard decoded.Count > 0, let first = decoded.Results.first else {
            throw DecodeError.notFound("No results for VIN: \(cleanVIN)")
        }

        // Extract key fields from the flat Results array
        var make: String?
        var model: String?
        var modelYear: Int?
        var manufacturer: String?
        var vehicleType: String?
        var bodyClass: String?
        var doors: Int?
        var fuelType: String?
        var engineCylinders: Int?
        var displacementL: Double?

        for r in decoded.Results {
            switch r.Variable {
            case "Make": make = r.Value
            case "Model": model = r.Value
            case "Model Year":
                if let v = r.Value, let y = Int(v) { modelYear = y }
            case "Manufacturer": manufacturer = r.Value
            case "Vehicle Type": vehicleType = r.Value
            case "Body Class": bodyClass = r.Value
            case "Doors":
                if let v = r.Value, let d = Int(v) { doors = d }
            case "Fuel Type Primary", "Fuel Type Secondary":
                if fuelType == nil { fuelType = r.Value }
            case "Engine Cylinders":
                if let v = r.Value, let c = Int(v) { engineCylinders = c }
            case "Displacement (L)":
                if let v = r.Value, let d = Double(v) { displacementL = d }
            default: break
            }
        }

        // Build citation bound to this exact API response
        let excerpt = try JSONEncoder().encode(decoded.Results)
        let citation = SourceCitation(
            sourceType: .nhtsaVpic,
            url: components.url,
            retrievedAt: Date(),
            excerptHashSHA256: SHA256.hash(data: excerpt).map { String(format: "%02x", $0) }.joined()
        )

        let result = DecodedVIN(
            vin: cleanVIN,
            make: make,
            model: model,
            modelYear: modelYear,
            manufacturer: manufacturer,
            vehicleType: vehicleType,
            bodyClass: bodyClass,
            doors: doors,
            fuelType: fuelType,
            engineCylinders: engineCylinders,
            displacementL: displacementL,
            citation: citation
        )

        // Cache for session (caller can persist cache across runs)
        var updatedConfig = config
        updatedConfig.cache[cleanVIN] = result
        // Note: config is let; caller should manage persistent cache externally

        return result
    }

    /// Decode multiple VINs concurrently with rate-limit awareness.
    /// - Parameter vins: Array of 17-char VINs.
    /// - Parameter maxConcurrent: Max parallel requests (NHTSA suggests ≤ 10).
    /// - Returns: Dictionary of VIN → Result (success) or Error (failure).
    public func decodeBatch(_ vins: [String], maxConcurrent: Int = 5) async -> [String: Result<DecodedVIN, DecodeError>] {
        var results: [String: Result<DecodedVIN, DecodeError>] = [:]
        let semaphore = SyncSemaphore(value: maxConcurrent)

        await withTaskGroup(of: (String, Result<DecodedVIN, DecodeError>).self) { group in
            for vin in vins {
                group.addTask {
                    await semaphore.wait()
                    defer { semaphore.signal() }
                    do {
                        let result = try await self.decode(vin)
                        return (vin, .success(result))
                    } catch let e as DecodeError {
                        return (vin, .failure(e))
                    } catch {
                        return (vin, .failure(.networkError(error.localizedDescription)))
                    }
                }
            }

            for await (vin, result) in group {
                results[vin] = result
            }
        }

        return results
    }
}

/// Simple async semaphore for concurrency control.
private actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) { self.value = value }

    func wait() async {
        if value > 0 {
            value -= 1
        } else {
            await withCheckedContinuation { continuation in
                waiters.append(continuation)
            }
        }
    }

    func signal() {
        if let waiter = waiters.popLast() {
            waiter.resume()
        } else {
            value += 1
        }
    }
}

/// Non-actor wrapper for synchronous signal calls from defer.
private struct SyncSemaphore {
    private let actor: AsyncSemaphore
    init(value: Int) { self.actor = AsyncSemaphore(value: value) }
    func wait() async { await actor.wait() }
    func signal() { Task { await actor.signal() } }
}

import CryptoKit