import AccountabilityKit
import Foundation
import Observation
import Security

/// Optional accounts for the court sources. Values live in the macOS Keychain only (never UserDefaults, never the
/// repo) and are typed by the user in the Records pane — nothing here reads, logs or transmits them except to the
/// matching court service.
enum RecordsCredentials {
    enum Item: String { case pacerLogin = "pacer-login", pacerPassword = "pacer-password", pacerClientCode = "pacer-client-code", courtListenerToken = "courtlistener-token" }
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
    /// Imported open-data rosters by source id (names + titles only; the portal is asked for nothing else).
    private(set) var rosterSnapshots: [String: RosterSnapshot] = [:]
    var rosterProgress: [String: Int] = [:]
    private let directory: URL

    private let trackerStore: JSONFileStore<FOIATracker>
    private let ledgerStore: JSONFileStore<RecordsLedger>
    private let budgetStore: JSONFileStore<PacerBudget>

    init(directory: URL = RecordsWorkspace.defaultDirectory) {
        self.directory = directory
        trackerStore = .init(url: directory.appendingPathComponent("foia-requests.json"))
        ledgerStore = .init(url: directory.appendingPathComponent("ledger.json"))
        budgetStore = .init(url: directory.appendingPathComponent("pacer-budget.json"))
        tracker = trackerStore.load(default: FOIATracker())
        ledger = ledgerStore.load(default: RecordsLedger())
        budget = budgetStore.load(default: PacerBudget())
        for source in RosterCatalog.all {
            let snap = rosterStore(source.id).load(default: RosterSnapshot(sourceID: source.id, importedAt: .distantPast, asOf: nil, entries: []))
            if !snap.entries.isEmpty { rosterSnapshots[source.id] = snap }
        }
    }

    private func rosterStore(_ id: String) -> JSONFileStore<RosterSnapshot> {
        JSONFileStore(url: directory.appendingPathComponent("roster-\(id).json"), pretty: false)
    }

    /// One-click import of a catalogue roster. Returns the entry count (0 on failure; the reason is in `lastError`).
    func importCatalogRoster(_ source: RosterSource) async -> Int {
        rosterProgress[source.id] = 0
        defer { rosterProgress[source.id] = nil }
        do {
            let snap = try await RosterFetcher().fetch(source) { n in Task { @MainActor in RecordsWorkspace.shared.rosterProgress[source.id] = n } }
            try rosterStore(source.id).save(snap)
            rosterSnapshots[source.id] = snap
            lastError = ""
            return snap.entries.count
        } catch { lastError = "Roster import failed (\(source.title)): \(error)"; return 0 }
    }

    func addOfficial(_ entry: RosterSnapshot.Entry, from source: RosterSource) -> OfficialProfile? {
        guard let snap = rosterSnapshots[source.id] else { return nil }
        do { return try ledger.addProfile(from: entry, snapshot: snap, source: source) }
        catch { lastError = "\(error)"; return nil }
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
            let dockets = try await client.findCases(partyName: partyName, loginID: login, password: password,
                                                     clientCode: RecordsCredentials.read(.pacerClientCode))
            budget = client.budget
            let now = Date()
            lastError = ""
            return ledger.add(dockets.map { $0.candidate(retrievedAt: now) })
        } catch PacerClient.Failure.budgetDenied(let reason) { lastError = reason; return 0 }
        catch PacerClient.Failure.authFailed(let why) { lastError = "PACER sign-in failed (\(why)). Check the username/password at pacer.uscourts.gov, and add a client code — PACER needs one for searches."; return 0 }
        catch { lastError = "PACER: \(error)"; return 0 }
    }

    func importList(csv: String, source: PublishedListImporter.Source, columns: PublishedListImporter.Columns) -> Int {
        do {
            let added = ledger.add(try PublishedListImporter().candidates(fromCSV: csv, source: source, columns: columns))
            lastError = ""
            return added
        } catch { lastError = "Import failed: \(error)"; return 0 }
    }

    func importRoster(csv: String, source: RosterImporter.Source, columns: RosterImporter.Columns) -> Int {
        do {
            let added = ledger.addRoster(try RosterImporter().candidates(fromCSV: csv, source: source, columns: columns))
            lastError = ""
            return added
        } catch { lastError = "Roster import failed: \(error)"; return 0 }
    }
}
