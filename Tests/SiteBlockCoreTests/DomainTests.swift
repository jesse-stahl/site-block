import XCTest
@testable import SiteBlockCore

final class DomainTests: XCTestCase {

    // MARK: normalize

    func testNormalizeBareDomain() {
        XCTAssertEqual(Domain.normalize("facebook.com"), "facebook.com")
    }

    func testNormalizeLowercasesAndTrims() {
        XCTAssertEqual(Domain.normalize("  Facebook.COM  "), "facebook.com")
    }

    func testNormalizeStripsScheme() {
        XCTAssertEqual(Domain.normalize("https://facebook.com"), "facebook.com")
        XCTAssertEqual(Domain.normalize("http://facebook.com"), "facebook.com")
    }

    func testNormalizeStripsPathQueryFragmentAndPort() {
        XCTAssertEqual(Domain.normalize("https://facebook.com/feed?x=1#top"), "facebook.com")
        XCTAssertEqual(Domain.normalize("facebook.com:8080"), "facebook.com")
    }

    func testNormalizeStripsLeadingWww() {
        XCTAssertEqual(Domain.normalize("www.facebook.com"), "facebook.com")
        XCTAssertEqual(Domain.normalize("https://www.facebook.com/x"), "facebook.com")
    }

    func testNormalizeStripsUserinfoAndTrailingDot() {
        XCTAssertEqual(Domain.normalize("user:pass@facebook.com"), "facebook.com")
        XCTAssertEqual(Domain.normalize("facebook.com."), "facebook.com")
    }

    func testNormalizeKeepsDeeperSubdomains() {
        XCTAssertEqual(Domain.normalize("news.ycombinator.com"), "news.ycombinator.com")
    }

    func testNormalizeRejectsInvalid() {
        XCTAssertNil(Domain.normalize(""))
        XCTAssertNil(Domain.normalize("   "))
        XCTAssertNil(Domain.normalize("not a domain"))
        XCTAssertNil(Domain.normalize("localhost"))          // no dot
        XCTAssertNil(Domain.normalize("foo."))                // empty TLD
        XCTAssertNil(Domain.normalize(".com"))                // empty label
        XCTAssertNil(Domain.normalize("foo..com"))            // empty label
        XCTAssertNil(Domain.normalize("foo.c"))               // TLD too short
        XCTAssertNil(Domain.normalize("foo.c0m"))             // non-alpha TLD
        XCTAssertNil(Domain.normalize("-bad.com"))            // label starts with hyphen
        XCTAssertNil(Domain.normalize("bad-.com"))            // label ends with hyphen
        XCTAssertNil(Domain.normalize("under_score.com"))     // illegal char
    }

    // MARK: expand

    func testExpandAddsWwwAndCommonSubdomains() {
        let entries = Domain.expand("facebook.com")
        XCTAssertEqual(entries.first, "facebook.com")
        XCTAssertTrue(entries.contains("www.facebook.com"))
        XCTAssertTrue(entries.contains("m.facebook.com"))
        XCTAssertTrue(entries.contains("mobile.facebook.com"))
        XCTAssertTrue(entries.contains("l.facebook.com"))
        XCTAssertTrue(entries.contains("web.facebook.com"))
    }

    func testExpandIsDeduplicatedAndBaseFirst() {
        let entries = Domain.expand("facebook.com")
        XCTAssertEqual(entries.count, Set(entries).count, "no duplicates")
        XCTAssertEqual(entries[0], "facebook.com", "base host is first")
    }

    // MARK: blocklistEntries

    func testBlocklistEntriesNormalizesThenExpands() {
        let entries = Domain.blocklistEntries(for: "https://www.Facebook.com/feed")
        XCTAssertEqual(entries.first, "facebook.com")
        XCTAssertTrue(entries.contains("www.facebook.com"))
    }

    func testBlocklistEntriesEmptyForInvalid() {
        XCTAssertEqual(Domain.blocklistEntries(for: "not a domain"), [])
    }

    func testBlocklistEntriesIdempotentOnWwwInput() {
        XCTAssertEqual(
            Domain.blocklistEntries(for: "www.facebook.com"),
            Domain.blocklistEntries(for: "facebook.com")
        )
    }
}
