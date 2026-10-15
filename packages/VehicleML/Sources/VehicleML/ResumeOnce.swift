import Foundation

/// Resumes a checked continuation at most once.
///
/// A Vision request reports a failure through its completion handler *and* by making `perform` throw. Resuming from both
/// traps (`CheckedContinuation.resume` twice — this crashed the Hub on a feed frame); this wrapper keeps the first result
/// and ignores the second.
final class ResumeOnce<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, any Error>?

    init(_ continuation: CheckedContinuation<Value, any Error>) { self.continuation = continuation }

    func resume(returning value: Value) { take()?.resume(returning: value) }
    func resume(throwing error: any Error) { take()?.resume(throwing: error) }

    private func take() -> CheckedContinuation<Value, any Error>? {
        lock.lock(); defer { lock.unlock() }
        defer { continuation = nil }
        return continuation
    }
}
