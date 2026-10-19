import Foundation
import PlateKit

/// A feed the operator chose to follow (agency press pages, records-portal release feeds, court or news feeds).
/// The Hub only ever *reads* feeds; subscriptions are local and never synced.
public struct RSSSubscription: Sendable, Codable, Identifiable, Hashable {
    public var id: UUID
    public var title: String
    public var url: URL
    public var addedAt: Date
    public var lastFetchedAt: Date?
    public var lastError: String?
    /// Optional free-form tag, e.g. "FOIA releases", "Courts".
    public var group: String

    public init(id: UUID = UUID(), title: String, url: URL, addedAt: Date = Date(), group: String = "") {
        self.id = id; self.title = title; self.url = url; self.addedAt = addedAt; self.group = group
    }
}

/// One entry as the publisher wrote it. Text is plain (markup stripped), never interpreted as instructions.
public struct RSSItem: Sendable, Codable, Identifiable, Hashable {
    /// Stable per (feed, guid-or-link) so refreshes never duplicate.
    public var id: String
    public var feedID: UUID
    public var title: String
    public var link: URL?
    public var summary: String
    public var author: String?
    public var publishedAt: Date?
    public var fetchedAt: Date
    public var isRead = false
    public var isStarred = false

    public static let maxSummary = 1200
}

/// What a parser returns before the library assigns feed ids.
public struct ParsedFeed: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public var guid: String
        public var title: String
        public var link: URL?
        public var summary: String
        public var author: String?
        public var publishedAt: Date?
    }
    public var title: String
    public var entries: [Entry]
}

public enum RSSParseError: Error, Equatable { case notAFeed, tooLarge }

/// RSS 2.0, RSS 1.0 (RDF) and Atom 1.0 via `XMLParser` (no DTD/external entity loading).
public enum RSSParser {
    public static let maxBytes = 3_000_000
    public static let maxEntries = 200

    public static func parse(_ data: Data) throws -> ParsedFeed {
        guard data.count <= maxBytes else { throw RSSParseError.tooLarge }
        let delegate = Delegate()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse() || !delegate.entries.isEmpty, delegate.sawFeedRoot else { throw RSSParseError.notAFeed }
        return ParsedFeed(title: clean(delegate.feedTitle), entries: Array(delegate.entries.prefix(maxEntries)))
    }

    // MARK: text helpers

    /// Strips tags, decodes the handful of entities feeds use, collapses whitespace.
    static func plain(_ html: String) -> String {
        var s = html
        if s.contains("<") {
            s = s.replacingOccurrences(of: "<(br|/p|/div|/li)[^>]*>", with: " ", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        }
        for (entity, char) in [("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                               ("&apos;", "'"), ("&nbsp;", " "), ("&#8217;", "\u{2019}"), ("&#8220;", "\u{201C}"), ("&#8221;", "\u{201D}")] {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return clean(s)
    }

    static func clean(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }

    /// Only http(s) links are kept; `javascript:`, `file:` and custom schemes are dropped.
    static func safeURL(_ s: String?) -> URL? {
        guard let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), let url = URL(string: s),
              let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https", url.host != nil else { return nil }
        return url
    }

    static func date(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if let d = try? Date(t, strategy: .iso8601) { return d }
        let frac = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
        if let d = try? Date(t, strategy: frac) { return d }
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z", "EEE, dd MMM yyyy HH:mm:ss zzz",
                       "dd MMM yyyy HH:mm:ss Z", "yyyy-MM-dd"] {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone(identifier: "UTC"); df.dateFormat = format
            if let d = df.date(from: t) { return d }
        }
        return nil
    }

    // MARK: delegate

    private final class Delegate: NSObject, XMLParserDelegate {
        var sawFeedRoot = false
        var feedTitle = ""
        var entries: [ParsedFeed.Entry] = []

        private var path: [String] = []
        private var text = ""
        private var current: Partial?

        struct Partial {
            var guid = "", title = "", link = "", altLink = "", summary = "", content = "", author = "", date = ""
        }

        func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?,
                    attributes: [String: String]) {
            let name = element.lowercased()
            if path.isEmpty, ["rss", "feed", "rdf:rdf", "rdf"].contains(name) { sawFeedRoot = true }
            path.append(name)
            text = ""
            if name == "item" || name == "entry" { current = Partial() }
            // Atom <link href=... rel=...>
            if name == "link", current != nil, let href = attributes["href"] {
                let rel = attributes["rel"] ?? "alternate"
                if rel == "alternate" { current?.altLink = href }
            }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { text += String(decoding: CDATABlock, as: UTF8.self) }

        func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
            let name = element.lowercased()
            defer { _ = path.popLast() }
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if current != nil, name != "item", name != "entry" {
                switch name {
                case "title": if current?.title.isEmpty == true { current?.title = value }
                case "link": if !value.isEmpty { current?.link = value }
                case "guid", "id": current?.guid = value
                case "description", "summary": current?.summary = value
                case "content:encoded", "content": current?.content = value
                case "pubdate", "published", "updated", "dc:date": if current?.date.isEmpty == true { current?.date = value }
                case "author", "dc:creator", "name":
                    if current?.author.isEmpty == true, !value.isEmpty { current?.author = value }
                default: break
                }
            } else if current == nil, name == "title", feedTitle.isEmpty, path.count <= 3 {
                feedTitle = value
            }
            if name == "item" || name == "entry", let p = current {
                current = nil
                let link = RSSParser.safeURL(p.link.isEmpty ? p.altLink : p.link) ?? RSSParser.safeURL(p.altLink)
                let title = RSSParser.plain(p.title)
                let body = RSSParser.plain(p.summary.isEmpty ? p.content : p.summary)
                guard !title.isEmpty || link != nil else { return }
                let guid = p.guid.isEmpty ? (link?.absoluteString ?? title) : p.guid
                entries.append(.init(guid: guid, title: title.isEmpty ? (link?.absoluteString ?? "") : title, link: link,
                                     summary: String(body.prefix(RSSItem.maxSummary)),
                                     author: p.author.isEmpty ? nil : RSSParser.plain(p.author),
                                     publishedAt: RSSParser.date(p.date)))
            }
            text = ""
        }
    }
}

/// Minimal OPML import/export so subscriptions move between readers.
public enum OPML {
    public static func parse(_ data: Data) -> [(title: String, url: URL, group: String)] {
        final class D: NSObject, XMLParserDelegate {
            var out: [(String, URL, String)] = []
            var groups: [String] = []
            func parser(_ p: XMLParser, didStartElement e: String, namespaceURI: String?, qualifiedName: String?, attributes a: [String: String]) {
                guard e.lowercased() == "outline" else { return }
                if let x = a["xmlUrl"] ?? a["xmlurl"], let url = RSSParser.safeURL(x) {
                    out.append((a["title"] ?? a["text"] ?? url.host ?? x, url, groups.last ?? ""))
                    groups.append(groups.last ?? "")
                } else { groups.append(a["title"] ?? a["text"] ?? "") }
            }
            func parser(_ p: XMLParser, didEndElement e: String, namespaceURI: String?, qualifiedName: String?) {
                if e.lowercased() == "outline" { _ = groups.popLast() }
            }
        }
        let d = D()
        let p = XMLParser(data: data)
        p.shouldResolveExternalEntities = false
        p.delegate = d
        p.parse()
        return d.out
    }

    public static func export(_ subs: [RSSSubscription]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let rows = subs.map { "    <outline type=\"rss\" text=\"\(esc($0.title))\" title=\"\(esc($0.title))\" xmlUrl=\"\(esc($0.url.absoluteString))\"/>" }
        return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<opml version=\"2.0\">\n  <head><title>PlateWatch subscriptions</title></head>\n  <body>\n"
            + rows.joined(separator: "\n") + "\n  </body>\n</opml>\n"
    }
}

/// Subscriptions plus their retained items, persisted with `JSONFileStore`.
public struct RSSLibrary: Sendable, Codable, Equatable {
    public static let maxItemsPerFeed = 300

    public var subscriptions: [RSSSubscription] = []
    public var items: [RSSItem] = []

    public init() {}

    public enum AddError: Error, Equatable { case notWebAddress, insecure, duplicate }

    /// Subscriptions must be https; plain http feeds can be altered in transit and are refused.
    @discardableResult
    public mutating func subscribe(title: String = "", url: URL, group: String = "") throws -> RSSSubscription {
        guard let scheme = url.scheme?.lowercased(), url.host != nil else { throw AddError.notWebAddress }
        guard scheme == "https" else { throw scheme == "http" ? AddError.insecure : AddError.notWebAddress }
        guard !subscriptions.contains(where: { $0.url == url }) else { throw AddError.duplicate }
        let sub = RSSSubscription(title: title.isEmpty ? (url.host ?? url.absoluteString) : title, url: url, group: group)
        subscriptions.append(sub)
        return sub
    }

    public mutating func unsubscribe(_ id: UUID) {
        subscriptions.removeAll { $0.id == id }
        items.removeAll { $0.feedID == id }
    }

    /// Merges a fetch result. Existing items keep read/starred flags; each feed retains its newest `maxItemsPerFeed`
    /// (starred items are never trimmed). Returns the number of new items.
    @discardableResult
    public mutating func merge(_ parsed: ParsedFeed, into feedID: UUID, at now: Date = Date()) -> Int {
        guard let si = subscriptions.firstIndex(where: { $0.id == feedID }) else { return 0 }
        subscriptions[si].lastFetchedAt = now
        subscriptions[si].lastError = nil
        if subscriptions[si].title == subscriptions[si].url.host, !parsed.title.isEmpty { subscriptions[si].title = parsed.title }
        var known = Set(items.filter { $0.feedID == feedID }.map(\.id))
        var added = 0
        for e in parsed.entries {
            let id = "\(feedID.uuidString)|\(e.guid)"
            guard known.insert(id).inserted else { continue }
            items.append(RSSItem(id: id, feedID: feedID, title: e.title, link: e.link, summary: e.summary, author: e.author,
                                 publishedAt: e.publishedAt, fetchedAt: now))
            added += 1
        }
        trim(feedID)
        return added
    }

    public mutating func recordFailure(_ message: String, for feedID: UUID) {
        if let i = subscriptions.firstIndex(where: { $0.id == feedID }) { subscriptions[i].lastError = message }
    }

    private mutating func trim(_ feedID: UUID) {
        let mine = items.filter { $0.feedID == feedID }.sorted { ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt) }
        guard mine.count > Self.maxItemsPerFeed else { return }
        let drop = Set(mine.dropFirst(Self.maxItemsPerFeed).filter { !$0.isStarred }.map(\.id))
        items.removeAll { drop.contains($0.id) }
    }

    public func unreadCount(for feedID: UUID? = nil) -> Int {
        items.filter { !$0.isRead && (feedID == nil || $0.feedID == feedID) }.count
    }

    public enum Filter: Sendable { case all, unread, starred }

    /// Newest first. `query` matches title, summary and author, case- and diacritic-insensitively.
    public func visible(feed: UUID? = nil, filter: Filter = .all, query: String = "") -> [RSSItem] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return items.filter { item in
            if let feed, item.feedID != feed { return false }
            switch filter {
            case .all: break
            case .unread: if item.isRead { return false }
            case .starred: if !item.isStarred { return false }
            }
            guard !q.isEmpty else { return true }
            return [item.title, item.summary, item.author ?? ""].contains { $0.range(of: q, options: [.caseInsensitive, .diacriticInsensitive]) != nil }
        }.sorted { ($0.publishedAt ?? $0.fetchedAt) > ($1.publishedAt ?? $1.fetchedAt) }
    }

    public mutating func setRead(_ read: Bool, itemIDs: [String]) {
        let set = Set(itemIDs)
        for i in items.indices where set.contains(items[i].id) { items[i].isRead = read }
    }

    public mutating func markAllRead(feed: UUID? = nil) {
        for i in items.indices where feed == nil || items[i].feedID == feed { items[i].isRead = true }
    }

    public mutating func toggleStar(_ id: String) {
        if let i = items.firstIndex(where: { $0.id == id }) { items[i].isStarred.toggle() }
    }

    /// An item becomes a *pending* news candidate: verbatim title + summary, cited to the entry URL. It is never
    /// accepted, linked to a person, or published automatically.
    public func candidate(for item: RSSItem, feedTitle: String, now: Date = Date()) -> RecordCandidate {
        let excerpt = item.summary.isEmpty ? item.title : "\(item.title) — \(item.summary)"
        return RecordCandidate(kind: .news, reference: item.link?.absoluteString ?? item.title, status: "",
                               subjectName: nil, agencyName: nil, releasedBy: feedTitle, filedOn: item.publishedAt,
                               excerpt: excerpt,
                               citation: SourceCitation(sourceType: .newsReport, url: item.link, retrievedAt: now,
                                                        excerptHashSHA256: Hashing.sha256Hex(String(excerpt.prefix(RecordCandidate.maxExcerpt)))))
    }
}

/// Fetches feeds over the shared `HTTPFetching` transport.
public struct RSSFetcher: Sendable {
    public enum FetchError: Error, Equatable, CustomStringConvertible {
        case insecure, http(Int)
        public var description: String {
            switch self { case .insecure: "Feed address must be https"; case .http(let c): "HTTP \(c)" }
        }
    }

    private let fetcher: HTTPFetching
    public init(fetcher: HTTPFetching = URLSessionFetcher()) { self.fetcher = fetcher }

    public func request(_ url: URL) -> URLRequest {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue("PlateWatch records reader (open-source accountability tool)", forHTTPHeaderField: "User-Agent")
        req.setValue("application/rss+xml, application/atom+xml, application/xml, text/xml;q=0.9", forHTTPHeaderField: "Accept")
        return req
    }

    public func fetch(_ url: URL) async throws -> ParsedFeed {
        guard url.scheme?.lowercased() == "https" else { throw FetchError.insecure }
        let (data, status) = try await fetcher.fetch(request(url))
        guard status == 200 else { throw FetchError.http(status) }
        return try RSSParser.parse(data)
    }
}
