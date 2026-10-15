import AccountabilityKit
import Foundation
import Observation
import Security

/// Optional accounts for the court sources. Values live in the macOS Keychain only (never UserDefaults, never the
/// repo) and are typed by the user in the Records pane — nothing here reads, logs or transmits them except to the
/// matching court service.
enum RecordsCredentials {
    enum Item: String { case pacerLogin = "pacer-login", pacerPassword = "pacer-password", courtListenerToken = "courtlistener-token" }
    private static let service = "org.platewatch.hub.records"

    static func read(_ item: Item) -> String? {
        var out: AnyObject?
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: item.rawValue, kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func has(_ item: Item) -> Bool { read(item) != nil }

    @discardableResult
    static func write(_ value: String, for item: Item) -> Bool {
        remove(item)
        guard !value.isEmpty else { return true }
        let attrs: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: item.rawValue, kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        return SecItemAdd(attrs as CFDictionary, nil) == errSecSuccess
    }

    static func remove(_ item: Item) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: item.rawValue]
        SecItemDelete(q as CFDictionary)
    }
}

/// Everything the Records pane edits: the FOIA tracker, the candidate/record ledger and the PACER budget, each saved
/// as JSON under Application Support/PlateWatchHub/records. Local only — nothing syncs or publishes.
@MainActor @Observable
final class RecordsWorkspace {
    static let shared = RecordsWorkspace()

    var tracker: FOIATracker { didSet { save(tracker, trackerStore) } }
    var ledger: RecordsLedger { didSet { save(ledger, ledgerStore) } }
    var budget: PacerBudget { didSet { save(budget, budgetStore) } }
    var lastError = ""

    private let trackerStore: JSONFileStore<FOIATracker>
    private let ledgerStore: JSONFileStore<RecordsLedger>
    private let budgetStore: JSONFileStore<PacerBudget>

    init(directory: URL = RecordsWorkspace.defaultDirectory) {
        trackerStore = .init(url: directory.appendingPathComponent("foia-requests.json"))
        ledgerStore = .init(url: directory.appendingPathComponent("ledger.json"))
        budgetStore = .init(url: directory.appendingPathComponent("pacer-budget.json"))
        tracker = trackerStore.load(default: FOIATracker())
        ledger = ledgerStore.load(default: RecordsLedger())
        budget = budgetStore.load(default: PacerBudget())
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlateWatchHub/records", isDirectory: true)
    }

    private func save<T: Codable & Sendable>(_ value: T, _ store: JSONFileStore<T>) {
        do { try store.save(value) } catch { lastError = "Could not save: \(error.localizedDescription)" }
    }

    /// Index used by the Review pane; rebuilt on demand (the ledger is small).
    var unitIndex: UnitRecordsIndex { UnitRecordsIndex(ledger: ledger) }

    /// Runs a CourtListener search and adds the dockets as pending candidates. Returns how many were new.
    func searchCourtListener(query: String) async -> Int {
        let client = CourtListenerClient(token: RecordsCredentials.read(.courtListenerToken))
        do {
            let dockets = try await client.search(query: query)
            let now = Date()
            lastError = ""
            return ledger.add(dockets.map { $0.candidate(retrievedAt: now) })
        } catch { lastError = "CourtListener: \(error)"; return 0 }
    }

    /// PACER party search with the user's own account. Refuses (without touching the network) when the budget says no.
    func searchPacer(partyName: String) async -> Int {
        guard let login = RecordsCredentials.read(.pacerLogin), let password = RecordsCredentials.read(.pacerPassword) else {
            lastError = "Add your PACER login in Court sources first."; return 0
        }
        var client = PacerClient(budget: budget)
        do {
            let dockets = try await client.findCases(partyName: partyName, loginID: login, password: password)
            budget = client.budget
            let now = Date()
            lastError = ""
            return ledger.add(dockets.map { $0.candidate(retrievedAt: now) })
        } catch PacerClient.Failure.budgetDenied(let reason) { lastError = reason; return 0 }
        catch { lastError = "PACER: \(error)"; return 0 }
    }

    func importList(csv: String, source: PublishedListImporter.Source, columns: PublishedListImporter.Columns) -> Int {
        do {
            let added = ledger.add(try PublishedListImporter().candidates(fromCSV: csv, source: source, columns: columns))
            lastError = ""
            return added
        } catch { lastError = "Import failed: \(error)"; return 0 }
    }
}
