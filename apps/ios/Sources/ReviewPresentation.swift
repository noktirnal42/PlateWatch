import Foundation
import PlateKit
import PlateSync

/// Matches only stable public IDs. Absence from a page is deliberately not a
/// withdrawal signal because feeds are paginated and moderation can be delayed.
enum ReceiptPublicationMatcher {
    static func publishedIDs(from sightings: [PublicSightingDTO]) -> Set<UUID> {
        Set(sightings.map(\.id))
    }
}

/// Presentation rules are separate from the recognition gate: manual fleet
/// watchlist entries may include short official, all-letter or numeric plates.
enum FleetWatchlistInput {
    static func validationMessage(_ raw: String, existing: [String]) -> String? {
        let normalized = Plate.normalize(raw)
        guard (2...10).contains(normalized.count),
              raw.unicodeScalars.allSatisfy({
                  (65...90).contains($0.value) || (97...122).contains($0.value) || (48...57).contains($0.value)
                  || CharacterSet.whitespaces.contains($0) || $0 == "-"
              }) else { return "Use 2–10 letters or digits. Spaces and hyphens are optional." }
        if existing.contains(where: { Plate.normalize($0) == normalized }) {
            return "This plate is already on your watchlist."
        }
        return nil
    }
}

struct SightingPresentation {
    let submission: SightingSubmissionDTO

    var title: String {
        if let agency = submission.identity?.agency, !agency.needsReview { return agency.name }
        let parts = [submission.markings?.serviceClassText?.capitalized,
                     submission.markings?.unitNumber.map { "Unit \($0)" }].compactMap { $0 }
        return parts.isEmpty ? "Public fleet vehicle" : parts.joined(separator: " · ")
    }

    /// Deliberately export an allowlisted summary rather than the raw DTO:
    /// no device identifier, exact coordinates, hashes, raw media or unreviewed agency claim.
    var shareText: String {
        var lines = ["PlateWatch · queued observation", title,
                     "Captured: \(submission.capturedAt.formatted(date: .abbreviated, time: .shortened))",
                     "Area: \(submission.geohash6.isEmpty ? "Not recorded" : submission.geohash6)"]
        if let plate = submission.plate { lines.append("Fleet plate: \(plate.text)") }
        if let unit = submission.markings?.unitNumber { lines.append("Unit: \(unit)") }
        lines.append("Fleet evidence score: \(Int(submission.fleetConfidence * 100))% (not a probability)")
        if submission.identity?.agency?.needsReview == true { lines.append("Agency: needs review") }
        lines.append("Queued locally. Backend receipt and publication have not been verified.")
        return lines.joined(separator: "\n")
    }
}

/// Rebuild the push-handler copy from current enabled entries, so deleting or
/// muting a plate removes it immediately rather than leaving a stale alert.
enum WatchlistNotificationMirror {
    static func plates(from entries: [WatchlistItem]) -> [String] {
        Array(Set(entries.filter(\.notifyEnabled).compactMap(\.plateText))).sorted()
    }
}
