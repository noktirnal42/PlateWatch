import XCTest
@testable import App

final class HeatmapSummaryTests: XCTestCase {
    private let since = Date(timeIntervalSince1970: 1_759_000_000)
    private let until = Date(timeIntervalSince1970: 1_760_000_000)

    private func points(_ hash: String, _ n: Int, day: TimeInterval = 0) -> [(geohash6: String, capturedAt: Date)] {
        (0..<n).map { _ in (hash, Date(timeIntervalSince1970: 1_759_500_000 + day)) }
    }

    func testSummarizeWithholdsSmallCellsAndDays() {
        let pts = points("9v6kpv", 5) + points("9v6kpw", 4)
        let report = AggregatesController.summarize(pts, since: since, until: until)
        XCTAssertEqual(report.cells, [.init(geohash6: "9v6kpv", count: 5)])
        XCTAssertEqual(report.withheldCells, 1)
        // All 9 sightings fall on one UTC day, which is at or above k in total.
        XCTAssertEqual(report.timeline.map(\.count), [9])
        XCTAssertEqual(report.withheldDays, 0)
    }

    func testSummarizeReportsWithheldDays() {
        // Three sightings per day on two days: each day is below k.
        let pts = points("9v6kpv", 3, day: 0) + points("9v6kpv", 3, day: 90_000)
        let report = AggregatesController.summarize(pts, since: since, until: until)
        XCTAssertTrue(report.timeline.isEmpty)
        XCTAssertEqual(report.withheldDays, 2)
    }

    func testEmptyInputPublishesNothing() {
        let report = AggregatesController.summarize([], since: since, until: until)
        XCTAssertTrue(report.cells.isEmpty)
        XCTAssertTrue(report.timeline.isEmpty)
        XCTAssertEqual(report.k, KAnonymity.k)
    }
}

final class HeatmapPageTests: XCTestCase {
    private func report(cells: [(String, Int)] = [], days: [(String, Int)] = [],
                        withheldCells: Int = 0) -> AggregatesController.HeatmapResponse {
        .init(k: KAnonymity.k,
              since: Date(timeIntervalSince1970: 1_759_000_000),
              until: Date(timeIntervalSince1970: 1_760_000_000),
              cells: cells.map { .init(geohash6: $0.0, count: $0.1) },
              timeline: days.map { .init(date: $0.0, count: $0.1) },
              withheldCells: withheldCells, withheldDays: 0)
    }

    func testEmptyWindowSaysSo() {
        let html = HeatmapPage.render(report())
        XCTAssertTrue(html.contains("No area has reached the publication threshold"))
        XCTAssertFalse(html.contains("<svg"))
    }

    func testPageHasNoScriptAndNoExternalRequests() {
        let html = HeatmapPage.render(report(cells: [("9v6kpv", 12)], days: [("2026-10-05", 12)]))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("http://"))
        XCTAssertFalse(html.contains("https://"))
        XCTAssertFalse(html.contains("<img"))
    }

    func testCellsAppearWithCountsAndTitles() {
        let html = HeatmapPage.render(report(cells: [("9v6kpv", 12), ("dqcjqc", 6)],
                                             days: [("2026-10-05", 18)]))
        XCTAssertTrue(html.contains("<title>9v6kpv: 12 sightings</title>"))
        XCTAssertTrue(html.contains("<td>12</td>"))
        XCTAssertTrue(html.contains("<title>2026-10-05: 18</title>"))
    }

    func testWithheldCountIsShownNotTheWithheldAreas() {
        let html = HeatmapPage.render(report(cells: [("9v6kpv", 12)], withheldCells: 3))
        XCTAssertTrue(html.contains("Areas withheld <strong>3</strong>"))
        XCTAssertFalse(html.contains("zzzzzz"))
    }

    func testHostileGeohashIsEscapedAndNotPlotted() {
        // Geohash strings come from the database; an invalid one must not be
        // plotted, and any text that is printed must be escaped.
        let html = HeatmapPage.render(report(cells: [("<script>x</script>", 9)]))
        XCTAssertFalse(html.contains("<script>x"))
        XCTAssertTrue(html.contains("&lt;script&gt;x&lt;/script&gt;"))
    }

    func testCSPForbidsScriptsAndFrames() {
        let csp = HeatmapPage.headers.first(name: "Content-Security-Policy") ?? ""
        XCTAssertTrue(csp.contains("default-src 'none'"))
        XCTAssertTrue(csp.contains("frame-ancestors 'none'"))
        XCTAssertFalse(csp.contains("script-src"))
    }
}
