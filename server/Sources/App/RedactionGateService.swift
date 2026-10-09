import Fluent
import Foundation
import Vapor

/// Server-side re-application of LEGAL-ETHICS Rule 1. The client gate is a
/// convenience; this gate is the boundary. Anything that can't pass here is
/// dropped with a reason recorded in the receipt.
enum RedactionGateService {

    struct GateOutcome {
        var state: ModerationState
        var exactGeoAllowed: Bool
        var dropReason: String?
    }

    enum ModerationState: String {
        case pending, fleetConfirmed, redacted, rejected
    }

    /// Server-side thresholds intentionally at-or-above client defaults:
    /// a misconfigured client can only ever be *more* permissive locally.
    static func evaluate(_ dto: SightingSubmissionDTO) -> GateOutcome {
        // Hard rejects: nothing is stored.
        if dto.fleetConfidence < 0.15 {
            return .init(state: .rejected, exactGeoAllowed: false,
                         dropReason: "below keep-on-device threshold")
        }
        // Fleet-confirmed: markings or known classification + strong signal.
        let hasMarkings = (dto.markings?.agencyText != nil) || (dto.markings?.unitNumber != nil)
        let governmentDesign = dto.plate?.plateDesign?.lowercased()
            .contains("gov") == true
            || dto.plate?.plateDesign?.lowercased().contains("exempt") == true
        let confirmed = dto.fleetConfidence >= 0.8
            && (hasMarkings || governmentDesign)
        if confirmed {
            return .init(state: .fleetConfirmed, exactGeoAllowed: true, dropReason: nil)
        }
        if dto.fleetConfidence >= 0.55 {
            // Persist for review, no exact geo.
            return .init(state: .pending, exactGeoAllowed: false, dropReason: nil)
        }
        return .init(state: .redacted, exactGeoAllowed: false,
                     dropReason: "insufficient fleet evidence — stored redacted if at all")
    }
}
