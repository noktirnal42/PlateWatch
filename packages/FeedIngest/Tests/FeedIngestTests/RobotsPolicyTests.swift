import Foundation
import XCTest
@testable import FeedIngest

final class RobotsPolicyTests: XCTestCase {
    private let userAgent = "PlateWatchHub"

    // MARK: - Group Selection

    func testSpecificUserAgentGroupSelected() {
        let text = """
        User-agent: PlateWatchHub
        Disallow: /private/
        User-agent: *
        Disallow: /
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/public/page"))
    }

    func testPrefixMatchUserAgent() {
        let text = """
        User-agent: platewatch
        Disallow: /private/
        User-agent: *
        Disallow: /
        """
        let policy = RobotsPolicy(parsing: text, userAgent: "PlateWatchHub/1.0")
        XCTAssertFalse(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/public/page"))
    }

    func testStarGroupFallback() {
        let text = """
        User-agent: Googlebot
        Disallow: /private/
        User-agent: *
        Disallow: /
        """
        let policy = RobotsPolicy(parsing: text, userAgent: "PlateWatchHub")
        XCTAssertFalse(policy.isAllowed(path: "/anything"))
    }

    func testNoMatchingGroupAllowsAll() {
        let text = """
        User-agent: Googlebot
        Disallow: /private/
        """
        let policy = RobotsPolicy(parsing: text, userAgent: "PlateWatchHub")
        XCTAssertTrue(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/public/page"))
    }

    // MARK: - Longest Match and Allow Wins Tie

    func testLongestMatchWins() {
        let text = """
        User-agent: *
        Disallow: /private/
        Allow: /private/public/
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/private/secret"))
        XCTAssertTrue(policy.isAllowed(path: "/private/public/page"))
    }

    func testAllowWinsTie() {
        let text = """
        User-agent: *
        Disallow: /page
        Allow: /page
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertTrue(policy.isAllowed(path: "/page"))
    }

    func testDisallowWinsWhenLonger() {
        let text = """
        User-agent: *
        Allow: /page
        Disallow: /page/secret
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertTrue(policy.isAllowed(path: "/page"))
        XCTAssertFalse(policy.isAllowed(path: "/page/secret"))
    }

    // MARK: - Wildcards and $ Anchor

    func testWildcardMatchesAnySequence() {
        let text = """
        User-agent: *
        Disallow: /*.pdf$
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/doc.pdf"))
        XCTAssertFalse(policy.isAllowed(path: "/folder/doc.pdf"))
        XCTAssertTrue(policy.isAllowed(path: "/doc.pdf.html"))
        XCTAssertTrue(policy.isAllowed(path: "/doc"))
    }

    func testEndAnchor() {
        let text = """
        User-agent: *
        Disallow: /page$
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/page"))
        XCTAssertTrue(policy.isAllowed(path: "/page/"))
        XCTAssertTrue(policy.isAllowed(path: "/page.html"))
    }

    func testWildcardInMiddle() {
        let text = """
        User-agent: *
        Disallow: /private/*/secret
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/private/folder/secret"))
        XCTAssertFalse(policy.isAllowed(path: "/private/a/b/c/secret"))
        XCTAssertTrue(policy.isAllowed(path: "/private/secret"))
        XCTAssertTrue(policy.isAllowed(path: "/public/secret"))
    }

    // MARK: - Comments and Line Endings

    func testCommentsIgnored() {
        let text = """
        # This is a comment
        User-agent: *
        Disallow: /private/  # inline comment
        Allow: /public/ # another comment
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/public/page"))
    }

    func testCRLFLineEndings() {
        let text = "User-agent: *\r\nDisallow: /private/\r\nAllow: /public/\r\n"
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/public/page"))
    }

    func testMixedLineEndings() {
        let text = "User-agent: *\nDisallow: /private/\r\nAllow: /public/\n"
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/public/page"))
    }

    // MARK: - Empty Disallow

    func testEmptyDisallowAllowsAll() {
        let text = """
        User-agent: *
        Disallow:
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertTrue(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/anything"))
    }

    func testEmptyDisallowWithOtherRules() {
        let text = """
        User-agent: *
        Disallow: /private/
        Disallow:
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        // Empty disallow should not override specific disallow
        // Actually per RFC: empty Disallow means allow all, but specific rules still apply
        // The longest match wins
        XCTAssertFalse(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/public/page"))
    }

    // MARK: - Multiple Groups for Same Agent

    func testMultipleGroupsForSameAgentMerged() {
        let text = """
        User-agent: PlateWatchHub
        Disallow: /a/
        User-agent: PlateWatchHub
        Disallow: /b/
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/a/page"))
        XCTAssertFalse(policy.isAllowed(path: "/b/page"))
        XCTAssertTrue(policy.isAllowed(path: "/c/page"))
    }

    func testMultipleUserAgentsShareRules() {
        let text = """
        User-agent: bot1
        User-agent: bot2
        Disallow: /private/
        """
        let policy1 = RobotsPolicy(parsing: text, userAgent: "bot1")
        let policy2 = RobotsPolicy(parsing: text, userAgent: "bot2")
        XCTAssertFalse(policy1.isAllowed(path: "/private/page"))
        XCTAssertFalse(policy2.isAllowed(path: "/private/page"))
    }

    // MARK: - Disallow Prefix but Allow Sub-path

    func testDisallowPrefixAllowSubpath() {
        let text = """
        User-agent: *
        Disallow: /folder/
        Allow: /folder/public/
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/folder/private"))
        XCTAssertTrue(policy.isAllowed(path: "/folder/public/page"))
        XCTAssertTrue(policy.isAllowed(path: "/other/page"))
    }

    // MARK: - Case Insensitive Field Names

    func testCaseInsensitiveFields() {
        let text = """
        USER-AGENT: *
        DISALLOW: /private/
        ALLOW: /public/
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/private/page"))
        XCTAssertTrue(policy.isAllowed(path: "/public/page"))
    }

    // MARK: - Query String Included in Path

    func testQueryStringIncluded() {
        let text = """
        User-agent: *
        Disallow: /search?
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/search?q=test"))
        XCTAssertTrue(policy.isAllowed(path: "/search"))
        XCTAssertTrue(policy.isAllowed(path: "/search/"))
    }

    // MARK: - Static Convenience

    func testAllowAllStatic() {
        let policy = RobotsPolicy.allowAll
        XCTAssertTrue(policy.isAllowed(path: "/anything"))
        XCTAssertTrue(policy.isAllowed(path: "/private/secret"))
    }

    func testDisallowAllStatic() {
        let policy = RobotsPolicy.disallowAll
        XCTAssertFalse(policy.isAllowed(path: "/anything"))
        XCTAssertFalse(policy.isAllowed(path: "/"))
    }

    // MARK: - Edge Cases

    func testEmptyRobotsTxtAllowsAll() {
        let policy = RobotsPolicy(parsing: "", userAgent: userAgent)
        XCTAssertTrue(policy.isAllowed(path: "/anything"))
    }

    func testOnlyCommentsAllowsAll() {
        let text = "# comment\n# another\n"
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertTrue(policy.isAllowed(path: "/anything"))
    }

    func testUnknownFieldsIgnored() {
        let text = """
        User-agent: *
        Crawl-delay: 10
        Disallow: /private/
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertFalse(policy.isAllowed(path: "/private/page"))
    }

    func testPathMustStartWithSlash() {
        let text = """
        User-agent: *
        Disallow: /private/
        """
        let policy = RobotsPolicy(parsing: text, userAgent: userAgent)
        XCTAssertTrue(policy.isAllowed(path: "private/page")) // no leading slash
    }
}