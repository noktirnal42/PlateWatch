import Foundation

/// A shared decoder budget for favorite tiles and previews. Watched streams
/// have their separate four-stream budget; opening a large grid cannot add a
/// decoder per tile. Cancellation removes queued previews before admission.
actor HLSPreviewBudget {
    private let capacity: Int
    private var active = 0
    private var waiters: [(UUID, CheckedContinuation<Bool, Never>)] = []
    init(capacity: Int = 2) { self.capacity = max(1, capacity) }
    func acquire() async -> Bool {
        let id = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else { continuation.resume(returning: false); return }
                if active < capacity { active += 1; continuation.resume(returning: true) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }
    func release() {
        if !waiters.isEmpty { waiters.removeFirst().1.resume(returning: true) }
        else { active = max(0, active - 1) }
    }
    private func cancel(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.0 == id }) else { return }
        waiters.remove(at: index).1.resume(returning: false)
    }
}
