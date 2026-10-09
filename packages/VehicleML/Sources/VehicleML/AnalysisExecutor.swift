import CoreVideo
import Foundation
import PlateKit

/// Serializes frame analysis with backpressure: live capture drops the
/// oldest queued frame when busy; imports must set `mode = .processAll`.
public actor AnalysisExecutor {

    public enum Mode: Sendable {
        case live        // drop-oldest under load
        case processAll  // file imports, hub batch work
    }

    private let pipeline: PlateAnalysisPipeline
    private let contextProvider: @Sendable () -> AnalysisContext
    private var busy = false

    public init(pipeline: PlateAnalysisPipeline,
                contextProvider: @escaping @Sendable () -> AnalysisContext) {
        self.pipeline = pipeline
        self.contextProvider = contextProvider
    }

    public func submit(_ frame: FramePacketLike,
                       mode: Mode = .live) async throws -> DetectionFrame? {
        if busy, mode == .live { return nil } // drop-oldest policy
        busy = true
        defer { busy = false }
        return try await pipeline.analyze(frame, context: contextProvider())
    }
}

#if canImport(FoundationModels)
import FoundationModels

/// On-device structured parsing of fleet markings using Apple Intelligence.
/// Replaces regex heuristics on iOS 26+ / macOS 26+ with guided generation
/// over the raw scene-text lines. Runs entirely on-device.
@available(iOS 26.0, macOS 26.0, *)
public enum FleetMarkingsLLMParser {

    @Generable
    public struct ParsedMarkings: Sendable {
        @Guide(description: "Government agency name if present, e.g. 'City of Austin Police Department'")
        public var agencyName: String?
        @Guide(description: "Fleet or unit number painted on the vehicle, digits/letters only")
        public var unitNumber: String?
        @Guide(description: "Service class word if visible: POLICE, FIRE, EMS, PUBLIC WORKS, TRANSIT…")
        public var serviceClass: String?
        @Guide(description: "true only if the text clearly indicates a government/public-service vehicle")
        public var isGovernmentFleet: Bool
    }

    /// Parse lines. Falls back to nil on any model refusal/failure so the
    /// caller can apply `SceneTextHeuristics` instead — never throws.
    public static func parse(_ lines: [String]) async -> FleetMarkings? {
        let prompt = """
        Text read from the side of a vehicle:
        \(lines.map { "- \($0)" }.joined(separator: "\n"))
        Extract fleet identification fields. Guess nothing.
        """
        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: ParsedMarkings.self)
            let value = response.content
            return FleetMarkings(agencyText: value.agencyName,
                                 unitNumber: value.unitNumber,
                                 serviceClassText: value.serviceClass,
                                 hasFleetKeyword: value.isGovernmentFleet)
        } catch {
            return nil
        }
    }
}
#endif
