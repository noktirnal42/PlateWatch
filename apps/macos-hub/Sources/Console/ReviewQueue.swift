import Foundation
import PlateSync
import PlateKit
import SwiftData

@MainActor
enum ReviewQueue {
    @discardableResult
    static func confirm(_ ids: Set<PersistentIdentifier>, context: ModelContext) throws -> Int {
        let selected = try context.fetch(FetchDescriptor<PendingSubmission>()).filter { ids.contains($0.persistentModelID) }
        for row in selected {
            var dto = try JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: row.payloadJSON)
            dto.userConfirmed = true
            row.payloadJSON = try JSONEncoder.withISODates.encode(dto)
            row.lastError = nil
        }
        do { try context.save() }
        catch { context.rollback(); throw error }
        return selected.count
    }

    /// Fetch before mutating: live @Query updates must not change a deletion loop.
    @discardableResult
    static func reject(_ ids: Set<PersistentIdentifier>, context: ModelContext,
                       archive: EvidenceArchive = .current) throws -> Int {
        let selected = try context.fetch(FetchDescriptor<PendingSubmission>()).filter { ids.contains($0.persistentModelID) }
        let hashes = Set(selected.compactMap { row in
            (try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: row.payloadJSON))?.cropHashSHA256?.lowercased()
        })
        for row in selected { context.delete(row) }
        do { try context.save() }
        catch { context.rollback(); throw error }
        // Explicit rejection removes the local backup only after the last
        // queued reference is gone. Recovery must not defeat deliberate deletion.
        if let remaining = try? context.fetch(FetchDescriptor<PendingSubmission>()) {
            let referenced = Set(remaining.compactMap { row in
                (try? JSONDecoder.withISODates.decode(SightingSubmissionDTO.self, from: row.payloadJSON))?.cropHashSHA256?.lowercased()
            })
            for hash in hashes.subtracting(referenced) { archive.remove(hash: hash) }
        }
        return selected.count
    }
}
