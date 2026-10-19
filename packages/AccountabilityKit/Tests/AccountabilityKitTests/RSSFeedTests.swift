import XCTest
@testable import AccountabilityKit
import PlateKit

final class RSSFeedTests: XCTestCase {
    private let rss = """
    <?xml version="1.0"?><rss version="2.0"><channel><title>City Records</title>
    <item><title>Fleet &amp;amp; policy release</title><link>https://example.gov/a</link><guid>a-1</guid>
    <pubDate>Fri, 02 Oct 2026 12:00:00 +0000</pubDate>
    <description><![CDATA[<p>New <b>ALPR</b> policy&nbsp;posted.</p>]]></description></item>
    <item><title>Bad link</title><link>javascript:alert(1)</link></item>
    </channel></rss>
    """
    private let atom = """
    <feed xmlns="http://www.w3.org/2005/Atom"><title>Court News</title>
    <entry><title>Docket update</title><id>urn:1</id><link rel="alternate" href="https://example.org/d1"/>
    <updated>2026-10-03T10:00:00Z</updated><summary>Hearing set.</summary><author><name>Clerk</name></author></entry></feed>
    """

    func testParsesRSSAndStripsMarkup() throws {
        let f = try RSSParser.parse(Data(rss.utf8))
        XCTAssertEqual(f.title, "City Records")
        XCTAssertEqual(f.entries.count, 2)
        XCTAssertEqual(f.entries[0].summary, "New ALPR policy posted.")
        XCTAssertEqual(f.entries[0].link?.absoluteString, "https://example.gov/a")
        XCTAssertNotNil(f.entries[0].publishedAt)
        XCTAssertNil(f.entries[1].link, "javascript: links are dropped")
    }

    func testParsesAtom() throws {
        let f = try RSSParser.parse(Data(atom.utf8))
        XCTAssertEqual(f.title, "Court News")
        XCTAssertEqual(f.entries.first?.link?.absoluteString, "https://example.org/d1")
        XCTAssertEqual(f.entries.first?.author, "Clerk")
        XCTAssertNotNil(f.entries.first?.publishedAt)
    }

    func testRejectsNonFeeds() {
        XCTAssertThrowsError(try RSSParser.parse(Data("<html><body>hi</body></html>".utf8)))
        XCTAssertThrowsError(try RSSParser.parse(Data(count: RSSParser.maxBytes + 1)))
    }

    func testSubscribeRules() throws {
        var lib = RSSLibrary()
        XCTAssertThrowsError(try lib.subscribe(url: URL(string: "http://example.gov/feed")!)) { XCTAssertEqual($0 as? RSSLibrary.AddError, .insecure) }
        XCTAssertThrowsError(try lib.subscribe(url: URL(string: "file:///etc/passwd")!))
        try lib.subscribe(url: URL(string: "https://example.gov/feed")!)
        XCTAssertThrowsError(try lib.subscribe(url: URL(string: "https://example.gov/feed")!)) { XCTAssertEqual($0 as? RSSLibrary.AddError, .duplicate) }
    }

    func testMergeDedupesAndKeepsFlags() throws {
        var lib = RSSLibrary()
        let sub = try lib.subscribe(url: URL(string: "https://example.gov/feed")!)
        let parsed = try RSSParser.parse(Data(rss.utf8))
        XCTAssertEqual(lib.merge(parsed, into: sub.id), 2)
        lib.toggleStar(lib.items[0].id)
        lib.markAllRead()
        XCTAssertEqual(lib.merge(parsed, into: sub.id), 0)
        XCTAssertEqual(lib.items.count, 2)
        XCTAssertTrue(lib.items.allSatisfy(\.isRead))
        XCTAssertEqual(lib.visible(filter: .starred).count, 1)
        XCTAssertEqual(lib.unreadCount(), 0)
        XCTAssertEqual(lib.subscriptions[0].title, "City Records", "host-placeholder title adopts the feed's title")
    }

    func testSearchAndOrdering() throws {
        var lib = RSSLibrary()
        let a = try lib.subscribe(url: URL(string: "https://a.example/feed")!)
        let b = try lib.subscribe(url: URL(string: "https://b.example/feed")!)
        lib.merge(try RSSParser.parse(Data(rss.utf8)), into: a.id, at: Date(timeIntervalSince1970: 0))
        lib.merge(try RSSParser.parse(Data(atom.utf8)), into: b.id)
        XCTAssertEqual(lib.visible().first?.title, "Docket update", "newest first")
        XCTAssertEqual(lib.visible(query: "alpr").count, 1)
        XCTAssertEqual(lib.visible(feed: b.id).count, 1)
        lib.unsubscribe(a.id)
        XCTAssertEqual(lib.items.count, 1)
    }

    func testTrimKeepsStarred() throws {
        var lib = RSSLibrary()
        let sub = try lib.subscribe(url: URL(string: "https://a.example/feed")!)
        let entries = (0..<(RSSLibrary.maxItemsPerFeed + 5)).map {
            ParsedFeed.Entry(guid: "g\($0)", title: "t\($0)", link: nil, summary: "",
                             author: nil, publishedAt: Date(timeIntervalSince1970: Double($0)))
        }
        lib.merge(ParsedFeed(title: "x", entries: entries), into: sub.id)
        XCTAssertEqual(lib.items.count, RSSLibrary.maxItemsPerFeed)
        XCTAssertFalse(lib.items.contains { $0.title == "t0" })
    }

    func testCandidateIsPendingAndCited() throws {
        var lib = RSSLibrary()
        let sub = try lib.subscribe(url: URL(string: "https://a.example/feed")!)
        lib.merge(try RSSParser.parse(Data(rss.utf8)), into: sub.id)
        let item = lib.items.first { $0.link != nil }!
        let c = lib.candidate(for: item, feedTitle: "City Records")
        XCTAssertEqual(c.review, .pending)
        XCTAssertEqual(c.kind, .news)
        XCTAssertEqual(c.citation.sourceType, .newsReport)
        XCTAssertEqual(c.citation.url, item.link)
        XCTAssertNotNil(c.citation.excerptHashSHA256)
        var ledger = RecordsLedger()
        XCTAssertEqual(ledger.add([c]), 1)
        XCTAssertEqual(ledger.add([lib.candidate(for: item, feedTitle: "City Records")]), 0, "re-saving is deduplicated")
    }

    func testOPMLRoundTrip() throws {
        var lib = RSSLibrary()
        try lib.subscribe(title: "A & B", url: URL(string: "https://a.example/feed?x=1&y=2")!)
        let parsed = OPML.parse(Data(OPML.export(lib.subscriptions).utf8))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed[0].title, "A & B")
        XCTAssertEqual(parsed[0].url.absoluteString, "https://a.example/feed?x=1&y=2")
    }

    func testFetcherRefusesHTTPAndBadStatus() async {
        struct F: HTTPFetching { let status: Int; func fetch(_ r: URLRequest) async throws -> (data: Data, status: Int) { (Data(), status) } }
        do { _ = try await RSSFetcher(fetcher: F(status: 200)).fetch(URL(string: "http://x.example/f")!); XCTFail() }
        catch { XCTAssertEqual(error as? RSSFetcher.FetchError, .insecure) }
        do { _ = try await RSSFetcher(fetcher: F(status: 404)).fetch(URL(string: "https://x.example/f")!); XCTFail() }
        catch { XCTAssertEqual(error as? RSSFetcher.FetchError, .http(404)) }
    }
}
