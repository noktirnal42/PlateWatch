import Foundation

/// The set of feeds a Hub knows about, persisted as `feeds.json`. A source is **runnable** only when a human has
/// confirmed its terms (`PublicFeedSource.mayBeAnalysed`); everything else is carried along as "awaiting terms" so
/// an imported catalogue (e.g. a city's open-data camera list) can be reviewed source by source without ever being
/// polled in the meantime (docs/FEED-SOURCES.md §5).
public struct FeedCatalogue: Codable, Sendable, Equatable {
    public var schemaVersion: Int
    public var sources: [PublicFeedSource]

    public init(schemaVersion: Int = 1, sources: [PublicFeedSource] = []) {
        self.schemaVersion = schemaVersion
        self.sources = sources
    }

    /// Sources a person has cleared for automated use.
    public var runnable: [PublicFeedSource] { sources.filter(\.mayBeAnalysed) }
    /// Sources still waiting for a human to read and record their terms.
    public var awaitingTerms: [PublicFeedSource] { sources.filter { !$0.mayBeAnalysed } }

    // MARK: Persistence (ISO-8601 dates, stable key order so the file diffs cleanly)

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(self)
    }

    public static func decode(_ data: Data) throws -> FeedCatalogue {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(FeedCatalogue.self, from: data)
    }

    public static func load(from url: URL) throws -> FeedCatalogue {
        try decode(Data(contentsOf: url))
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}

public extension FeedCatalogue {

    /// Folds a freshly imported list of sources (e.g. a city's open-data camera list) into this catalogue **without
    /// disturbing human decisions**:
    ///  - a source already known by id keeps its recorded terms and confirmation, and its stated resolution;
    ///    its name, URL, position and citation are refreshed from the import (portals change URLs — Iowa did in 2026);
    ///  - **if the image host changed**, the confirmation is withdrawn (`automatedUseAllowed = false`): the terms a person
    ///    read applied to the old host, not the new one;
    ///  - brand-new sources are added exactly as imported (unconfirmed);
    ///  - sources missing from the import are kept (a catalogue outage must not silently delete anything).
    func merged(with imported: [PublicFeedSource]) -> FeedCatalogue {
        var result = sources
        var index = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($1.id, $0) })
        for fresh in imported {
            guard let i = index[fresh.id] else {
                index[fresh.id] = result.count
                result.append(fresh)
                continue
            }
            var kept = fresh
            kept.terms = result[i].terms
            kept.nativeLongSide = result[i].nativeLongSide ?? fresh.nativeLongSide
            if result[i].url.host?.lowercased() != fresh.url.host?.lowercased() {
                kept.terms.automatedUseAllowed = false
            }
            result[i] = kept
        }
        return FeedCatalogue(schemaVersion: schemaVersion, sources: result)
    }
}
