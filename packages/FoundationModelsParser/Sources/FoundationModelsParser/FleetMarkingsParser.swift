import Foundation
import FoundationModels
import PlateKit

/// Fleet markings extracted by FoundationModels structured generation.
/// This replaces the heuristic parser on iOS 26+/macOS 26+ with Apple Intelligence.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
@Generable
public struct ParsedFleetMarkings {
    /// Agency name (e.g., "Austin Police Department", "City of Seattle Fire Dept")
    @Guide(description: "Full official agency name if visible; nil if not readable")
    public var agencyName: String?

    /// Unit identifier (e.g., "4421", "ENGINE-42", "CAR-12")
    @Guide(description: "Unit/vehicle number as shown on the vehicle; nil if not visible")
    public var unitNumber: String?

    /// Service class (e.g., "POLICE", "FIRE", "EMS", "PUBLIC WORKS")
    @Guide(description: "Service category word visible on the vehicle")
    public var serviceClass: String?

    /// Ownership/organization line (e.g., "CITY OF AUSTIN", "DEPARTMENT OF TRANSPORTATION")
    @Guide(description: "Ownership/government entity line if visible")
    public var ownershipLine: String?

    /// Confidence 0-1 for the overall parse
    @Guide(description: "Confidence that the extracted fields are correct")
    public var confidence: Double
}

/// Natural language prompt for the fleet markings parser.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
private let fleetMarkingsPrompt = """
You are analyzing text detected on a government/emergency vehicle.
Extract structured fleet markings from the OCR text lines below.

OCR TEXT LINES:
{{ocr_lines}}

INSTRUCTIONS:
- agencyName: Full official agency name (e.g., "Austin Police Department", "Seattle Fire Department")
- unitNumber: Vehicle/unit identifier as shown (e.g., "4421", "ENGINE-42", "CAR 12", "LADDER-3")
- serviceClass: One service keyword if visible: POLICE, FIRE, EMS, PUBLIC WORKS, TRANSIT, SHERIFF, etc.
- ownershipLine: Government ownership line (e.g., "CITY OF AUSTIN", "STATE OF TEXAS", "U.S. GOVERNMENT")
- confidence: 0.0-1.0 overall confidence in the extraction

Return nil/empty for fields not clearly visible. Do not hallucinate.
"""

/// Parse fleet markings using FoundationModels (requires Apple Intelligence, iOS 26+/macOS 26+).
/// Falls back to SceneTextHeuristics if unavailable.
@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
public struct FleetMarkingsParser {
    private let session: LanguageModelSession
    private let heuristicFallback = true

    public init() async throws {
        // Check if Apple Intelligence is available
        let availability = SystemLanguageModel.default.availability
        guard case .available = availability else {
            throw FleetMarkingsError.appleIntelligenceUnavailable(availability)
        }
        self.session = LanguageModelSession(model: .default, tools: [])
    }

    /// Parse fleet markings from scene text observations.
    /// Returns ParsedFleetMarkings on success, or throws if FoundationModels unavailable.
    public func parse(_ observations: [SceneTextObservation]) async throws -> ParsedFleetMarkings {
        let ocrLines = observations.map { $0.text }.joined(separator: "\n")

        let prompt = fleetMarkingsPrompt
            .replacingOccurrences(of: "{{ocr_lines}}", with: ocrLines)

        let response = try await session.respond(to: prompt, generating: ParsedFleetMarkings.self)
        return response.content
    }

    /// Parse with heuristic fallback (always returns a result).
    public func parseWithFallback(_ observations: [SceneTextObservation]) async throws -> FleetMarkings {
        do {
            let parsed = try await parse(observations)
            return FleetMarkings(
                agencyText: parsed.agencyName,
                unitNumber: parsed.unitNumber,
                serviceClassText: parsed.serviceClass,
                hasFleetKeyword: parsed.serviceClass != nil || parsed.ownershipLine != nil
            )
        } catch {
            if heuristicFallback {
                return SceneTextHeuristics.parse(observations)
            }
            throw error
        }
    }
}

@available(macOS 26.0, iOS 26.0, watchOS 26.0, tvOS 26.0, *)
public enum FleetMarkingsError: Error, Sendable {
    case appleIntelligenceUnavailable(SystemLanguageModel.Availability)
    case generationFailed(Error)
}