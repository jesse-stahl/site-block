import XCTest
@testable import SiteBlockCore

final class BlockListTests: XCTestCase {

    // MARK: model

    func testAddNormalizesAndDeduplicates() {
        var list = BlockList()
        XCTAssertTrue(list.add("https://www.Facebook.com/feed"))
        XCTAssertFalse(list.add("facebook.com"), "same canonical domain is a duplicate")
        XCTAssertEqual(list.domains, ["facebook.com"])
    }

    func testAddRejectsInvalid() {
        var list = BlockList()
        XCTAssertFalse(list.add("not a domain"))
        XCTAssertTrue(list.domains.isEmpty)
    }

    func testRemove() {
        var list = BlockList(domains: ["facebook.com", "x.com"])
        XCTAssertTrue(list.remove("www.facebook.com")) // normalized match
        XCTAssertEqual(list.domains, ["x.com"])
        XCTAssertFalse(list.remove("nothere.com"))
    }

    func testAllBlockedHostsExpandsAndDedupes() {
        let list = BlockList(domains: ["facebook.com"])
        let hosts = list.allBlockedHosts()
        XCTAssertEqual(hosts.first, "facebook.com")
        XCTAssertTrue(hosts.contains("www.facebook.com"))
        XCTAssertTrue(hosts.contains("m.facebook.com"))
        XCTAssertEqual(hosts.count, Set(hosts).count)
    }

    // MARK: persistence

    func testCodableRoundTripHasNoTimerState() throws {
        let list = BlockList(domains: ["facebook.com"], isBlocking: true)
        let data = try JSONEncoder().encode(list)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("domains"))
        XCTAssertTrue(json.contains("isBlocking"))
        // No transient timer state leaks into the persisted form.
        XCTAssertFalse(json.lowercased().contains("cooling"))
        XCTAssertFalse(json.lowercased().contains("deadline"))
        // (The configured gate LENGTHS — `settings.windowMinutes` — are persisted on purpose.)
        XCTAssertFalse(json.lowercased().contains("windowends"))
        XCTAssertFalse(json.lowercased().contains("armed"))

        let decoded = try JSONDecoder().decode(BlockList.self, from: data)
        XCTAssertEqual(decoded, list)
    }

    func testStoreLoadMissingReturnsEmptyDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-\(UUID().uuidString)/blocklist.json")
        let store = BlockListStore(url: url)
        XCTAssertEqual(try store.load(), BlockList())
    }

    func testStoreSaveThenLoad() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlockListStore(url: dir.appendingPathComponent("blocklist.json"))

        var list = BlockList()
        list.add("facebook.com")
        list.add("x.com")
        list.isBlocking = true
        try store.save(list)

        XCTAssertEqual(try store.load(), list)
    }

    func testStoreSaveCreatesDirectory() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-\(UUID().uuidString)/nested/deeper", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: FileManager.default.temporaryDirectory
            .appendingPathComponent(dir.pathComponents[dir.pathComponents.count - 3])) }
        let store = BlockListStore(url: dir.appendingPathComponent("blocklist.json"))
        try store.save(BlockList(domains: ["a.com"]))
        XCTAssertEqual(try store.load().domains, ["a.com"])
    }
}
