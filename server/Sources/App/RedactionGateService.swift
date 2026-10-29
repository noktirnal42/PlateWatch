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
        // Sensitive vehicles (docs/FEED-SOURCES.md §6b): tactical/protective units, school buses and ambulances never
        // auto-confirm; a moderator must look, with no exact geo, whatever the confidence.
        if isSensitive(dto), dto.fleetConfidence >= 0.15 {
            return .init(state: .pending, exactGeoAllowed: false,
                         dropReason: "sensitive vehicle class — moderator review only")
        }
        // Fleet-confirmed: markings or known classification + strong signal.
        let hasMarkings = (dto.markings?.agencyText != nil) || (dto.markings?.unitNumber != nil)
        let governmentDesign = dto.plate?.plateDesign?.lowercased()
            .contains("gov") == true
            || dto.plate?.plateDesign?.lowercased().contains("exempt") == true
        // Preserve compatibility with pre-confirmation clients that omit the
        // field; new Hub payloads write false until an operator confirms.
        let operatorConfirmed = dto.userConfirmed ?? true
        let confirmed = operatorConfirmed && dto.fleetConfidence >= 0.8
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

    /// Words that mark vehicles whose location should not be published automatically. Matched on whole words in the
    /// OCR'd markings, the vehicle class and the field note; a miss is not proof of safety, hence moderator review.
    static let sensitiveTerms: Set<String> = ["swat", "tactical", "protective", "executive", "dignitary", "undercover",
                                              "school", "ambulance", "medic", "paramedic", "ems", "hearse"]

    static func isSensitive(_ dto: SightingSubmissionDTO) -> Bool {
        let text = [dto.markings?.agencyText, dto.markings?.serviceClassText, dto.markings?.note, dto.vehicle.vehicleClass]
            .compactMap { $0 }.joined(separator: " ").lowercased()
        let words = Set(text.split(whereSeparator: { !$0.isLetter }).map(String.init))
        return !words.isDisjoint(with: sensitiveTerms)
    }
}
