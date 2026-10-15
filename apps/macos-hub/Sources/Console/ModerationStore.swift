import Foundation
import SwiftUI

/// Load each moderator surface independently. A failed audit request must never masquerade as an empty successful log.
@MainActor
final class ModerationStore: ObservableObject {
    @Published private(set) var items: [ModerationClient.Item] = []
    @Published private(set) var takedowns: [ModerationClient.Takedown] = []
    @Published private(set) var audit: [ModerationClient.AuditEntry] = []
    @Published private(set) var queueError: String?
    @Published private(set) var takedownError: String?
    @Published private(set) var auditError: String?
    @Published private(set) var actionError: String?
    @Published private(set) var busy = false
    @Published private(set) var lastLoadedAt: Date?
    private var client: ModerationClient?

    init(client: ModerationClient? = nil) { self.client = client }

    func connect() async {
        if client == nil { client = await Task.detached { ModerationClient() }.value }
        guard !Task.isCancelled else { return }
        await refresh()
    }

    func refresh() async {
        guard !busy else { return }
        guard let client else {
            let message = ModerationClient.ClientError.notEnrolled.localizedDescription
            queueError = message; auditError = message; takedownError = message
            return
        }
        busy = true
        defer { busy = false }
        async let q: Void = loadQueue(client)
        async let t: Void = loadTakedowns(client)
        async let a: Void = loadAudit(client)
        _ = await (q, t, a)
        if !Task.isCancelled { lastLoadedAt = Date() }
    }

    private func loadQueue(_ client: ModerationClient) async {
        do {
            let result = try await client.queue()
            guard !Task.isCancelled else { return }
            items = result; queueError = nil
        } catch { if !Task.isCancelled { queueError = error.localizedDescription } }
    }
    private func loadTakedowns(_ client: ModerationClient) async {
        do {
            let result = try await client.takedowns()
            guard !Task.isCancelled else { return }
            takedowns = result; takedownError = nil
        } catch { if !Task.isCancelled { takedownError = error.localizedDescription } }
    }
    private func loadAudit(_ client: ModerationClient) async {
        do {
            let result = try await client.audit()
            guard !Task.isCancelled else { return }
            audit = result; auditError = nil
        } catch { if !Task.isCancelled { auditError = error.localizedDescription } }
    }

    func decide(_ id: UUID, decision: ModerationClient.Decision) async -> Bool {
        guard !busy, let client else { return false }
        busy = true; defer { busy = false }
        do {
            try await client.decide(id, decision)
            items.removeAll { $0.id == id }; actionError = nil
            await loadAudit(client)
            return true
        } catch { actionError = error.localizedDescription; return false }
    }

    func resolve(_ id: UUID, hide: Bool) async -> Bool {
        guard !busy, let client else { return false }
        busy = true; defer { busy = false }
        do {
            try await client.resolve(id, hide: hide)
            takedowns.removeAll { $0.id == id }; actionError = nil
            await loadAudit(client)
            return true
        } catch { actionError = error.localizedDescription; return false }
    }
}
