import PlateSync
import SwiftData

@MainActor
enum ReviewQueue {
    /// Fetch before mutating: live @Query updates must not change a deletion loop.
    @discardableResult
    static func reject(_ ids: Set<PersistentIdentifier>, context: ModelContext) throws -> Int {
        let selected = try context.fetch(FetchDescriptor<PendingSubmission>()).filter { ids.contains($0.persistentModelID) }
        for row in selected { context.delete(row) }
        do { try context.save() }
        catch { context.rollback(); throw error }
        return selected.count
    }
}
