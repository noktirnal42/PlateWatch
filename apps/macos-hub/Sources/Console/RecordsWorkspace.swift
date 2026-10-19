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
    var rss: RSSLibrary { didSet { save(rss, rssStore) } }
    private(set) var refreshingFeeds: Set<UUID> = []
    /// Minutes between automatic refreshes of every followed feed; 0 = off. Persisted in UserDefaults.
    var autoRefreshMinutes: Int = UserDefaults.standard.integer(forKey: "hubRecords_rssAutoRefreshMinutes") {
        didSet {
            UserDefaults.standard.set(autoRefreshMinutes, forKey: "hubRecords_rssAutoRefreshMinutes")
            startAutoRefresh()
        }
    }
    private(set) var lastAutoRefresh: Date?
    private var autoRefreshTask: Task<Void, Never>?
    var lastError = ""
    private(set) var currentCourtQuery = ""
    private(set) var currentCourtSource = ""
    private(set) var courtSearchRunning = false
    private var courtSearchGeneration = UUID()
    private var currentCourtIDs: Set<UUID> = []

    var currentCourtResults: [RecordCandidate] {
        ledger.pending.filter { currentCourtIDs.contains($0.id) }
    }

    /// Search membership is transient; saved candidates and accepted records are never deleted by a search.
    @discardableResult
    func runCourtSearch(query: String, source: String,
                        fetch: () async throws -> [RecordCandidate]) async -> Int {
        let generation = UUID()
        courtSearchGeneration = generation
        currentCourtQuery = query
        currentCourtSource = source
        currentCourtIDs = []
        courtSearchRunning = true
        lastError = ""
        defer { if courtSearchGeneration == generation { courtSearchRunning = false } }
        do {
            let found = try await fetch()
            guard courtSearchGeneration == generation else { return 0 }
            let added = ledger.add(found)
            // Ledger deduplication retains the original UUID, including when the same search is repeated.
            let keys = Set(found.map(Self.courtKey))
            currentCourtIDs = Set(ledger.candidates.filter { keys.contains(Self.courtKey($0)) }.map(\.id))
            return added
        } catch {
            guard courtSearchGeneration == generation else { return 0 }
            lastError = "\(source): \(error)"
            return 0
        }
    }

    private static func courtKey(_ c: RecordCandidate) -> String {
        "\(c.kind.rawValue)|\(c.reference)|\(c.citation.excerptHashSHA256 ?? "")"
    }
    /// Imported open-data rosters by source id (names + titles only; the portal is asked for nothing else).
    private(set) var rosterSnapshots: [String: RosterSnapshot] = [:]
    var rosterProgress: [String: Int] = [:]
    private let directory: URL

    private let trackerStore: JSONFileStore<FOIATracker>
    private let ledgerStore: JSONFileStore<RecordsLedger>
    private let budgetStore: JSONFileStore<PacerBudget>
    private let rssStore: JSONFileStore<RSSLibrary>

    init(directory: URL = RecordsWorkspace.defaultDirectory) {
        self.directory = directory
        trackerStore = .init(url: directory.appendingPathComponent("foia-requests.json"))
        ledgerStore = .init(url: directory.appendingPathComponent("ledger.json"))
        budgetStore = .init(url: directory.appendingPathComponent("pacer-budget.json"))
        rssStore = .init(url: directory.appendingPathComponent("rss-feeds.json"))
        tracker = trackerStore.load(default: FOIATracker())
        ledger = ledgerStore.load(default: RecordsLedger())
        budget = budgetStore.load(default: PacerBudget())
        rss = rssStore.load(default: RSSLibrary())
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
        #if DEBUG
        if CommandLine.arguments.contains("-PWVisualQA") { return FileManager.default.temporaryDirectory.appendingPathComponent("PlateWatchVisualQA/records") }
        #endif
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PlateWatchHub/records", isDirectory: true)
    }

    private func save<T: Codable & Sendable>(_ value: T, _ store: JSONFileStore<T>) {
        do { try store.save(value) } catch { lastError = "Could not save: \(error.localizedDescription)" }
    }

    /// Index used by the Review pane; rebuilt on demand (the ledger is small).
    var unitIndex: UnitRecordsIndex { UnitRecordsIndex(ledger: ledger) }

    /// Runs a CourtListener search and replaces the visible search results, preserving saved candidates.
    func searchCourtListener(query: String) async -> Int {
        let client = CourtListenerClient(token: RecordsCredentials.read(.courtListenerToken))
        return await runCourtSearch(query: query, source: "CourtListener") {
            let dockets = try await client.search(query: query)
            let now = Date()
            return dockets.map { $0.candidate(retrievedAt: now) }
        }
    }

    /// PACER party search with the user's own account and existing budget controls.
    func searchPacer(partyName: String, otpCode: String? = nil) async -> Int {
        return await runCourtSearch(query: partyName, source: "PACER") {
            guard let login = RecordsCredentials.read(.pacerLogin), let password = RecordsCredentials.read(.pacerPassword) else {
                throw CourtSearchFailure.message("Add your PACER login in Court sources first.")
            }
            var client = PacerClient(budget: budget)
            do {
                let dockets = try await client.findCases(partyName: partyName, loginID: login, password: password,
                                                         clientCode: RecordsCredentials.read(.pacerClientCode), otpCode: otpCode)
                budget = client.budget
                let now = Date()
                return dockets.map { $0.candidate(retrievedAt: now) }
            } catch PacerClient.Failure.budgetDenied(let reason) { throw CourtSearchFailure.message(reason) }
            catch PacerClient.Failure.authFailed(let why) {
                throw CourtSearchFailure.message("Sign-in failed (\(why)). Check your PACER credentials and client code.")
            }
        }
    }

    private enum CourtSearchFailure: Error, CustomStringConvertible {
        case message(String)
        var description: String { switch self { case .message(let text): text } }
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

    /// One-click import of a catalogue list into pending candidates. Returns how many were new.
    func importKnownList(_ source: RecordSource) async -> Int {
        do {
            let found = try await RecordSourceFetcher().candidates(from: source)
            lastError = ""
            return ledger.add(found)
        } catch { lastError = "Import failed (\(source.title)): \(error)"; return 0 }
    }

    // MARK: RSS reader

    /// Fetches one feed (https only, size-capped). Failures are kept on the subscription, not thrown.
    @discardableResult
    func refreshFeed(_ id: UUID) async -> Int {
        guard let sub = rss.subscriptions.first(where: { $0.id == id }), refreshingFeeds.insert(id).inserted else { return 0 }
        defer { refreshingFeeds.remove(id) }
        do {
            let parsed = try await RSSFetcher().fetch(sub.url)
            return rss.merge(parsed, into: id)
        } catch {
            rss.recordFailure("\(error)", for: id)
            return 0
        }
    }

    /// Refreshes every subscription sequentially so no host is hit in parallel.
    @discardableResult
    func refreshAllFeeds() async -> Int {
        var added = 0
        for sub in rss.subscriptions { added += await refreshFeed(sub.id) }
        return added
    }

    /// (Re)starts the timer. Safe to call repeatedly; one loop runs at a time and it sleeps between passes.
    func startAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
        guard autoRefreshMinutes > 0 else { return }
        let interval = autoRefreshMinutes
        autoRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval * 60))
                guard !Task.isCancelled, let self else { return }
                await self.refreshAllFeeds()
                self.lastAutoRefresh = Date()
            }
        }
    }

    func subscribeToFeed(urlText: String, title: String = "", group: String = "") async -> Bool {
        guard let url = URL(string: urlText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            lastError = "That is not a valid web address."; return false
        }
        do {
            let sub = try rss.subscribe(title: title, url: url, group: group)
            lastError = ""
            await refreshFeed(sub.id)
            return true
        } catch RSSLibrary.AddError.insecure { lastError = "Feed addresses must start with https://"
        } catch RSSLibrary.AddError.duplicate { lastError = "You already follow that feed."
        } catch { lastError = "That is not a valid feed address." }
        return false
    }

    func importOPML(_ data: Data) -> Int {
        var added = 0
        for entry in OPML.parse(data) {
            if (try? rss.subscribe(title: entry.title, url: entry.url, group: entry.group)) != nil { added += 1 }
        }
        return added
    }

    /// Saves a feed entry as a *pending* cited candidate in the normal review queue.
    @discardableResult
    func saveFeedItemForReview(_ item: RSSItem) -> Bool {
        let title = rss.subscriptions.first { $0.id == item.feedID }?.title ?? "RSS feed"
        return ledger.add([rss.candidate(for: item, feedTitle: title)]) > 0
    }
}
