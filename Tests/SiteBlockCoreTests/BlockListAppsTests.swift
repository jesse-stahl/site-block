import XCTest
@testable import SiteBlockCore

final class BlockListAppsTests: XCTestCase {

    func testAddAppTrimsAndDeduplicatesByBundleIDCaseInsensitively() {
        var list = BlockList()
        XCTAssertTrue(list.addApp(bundleID: "  com.hnc.Discord ", name: "Discord"))
        XCTAssertFalse(list.addApp(bundleID: "com.hnc.discord", name: "Discord (again)"),
                       "same bundle id (case-insensitive) is a duplicate")
        XCTAssertEqual(list.apps, [BlockedApp(bundleID: "com.hnc.Discord", name: "Discord")])
    }

    func testAddAppRejectsEmpty() {
        var list = BlockList()
        XCTAssertFalse(list.addApp(bundleID: "   ", name: "Nothing"))
        XCTAssertFalse(list.addApp(bundleID: "com.example.app", name: "  "))
        XCTAssertTrue(list.apps.isEmpty)
    }

    func testAddAppRejectsNeverBlockableApps() {
        var list = BlockList()
        XCTAssertFalse(list.addApp(bundleID: "com.apple.Finder", name: "Finder"))
        XCTAssertFalse(list.addApp(bundleID: "today.siteblock.SiteBlock", name: "SiteBlock"))
        XCTAssertTrue(list.apps.isEmpty)
        XCTAssertFalse(AppBlockPolicy.isBlockable("COM.APPLE.LOGINWINDOW"))
        XCTAssertTrue(AppBlockPolicy.isBlockable("com.hnc.Discord"))
    }

    func testAppLookupReturnsCanonicalEntry() {
        let list = BlockList(apps: [BlockedApp(bundleID: "com.hnc.Discord", name: "Discord")])
        XCTAssertEqual(list.app(for: "COM.HNC.DISCORD")?.bundleID, "com.hnc.Discord")
        XCTAssertNil(list.app(for: "com.nothere"))
    }

    func testRemoveApp() {
        var list = BlockList(apps: [BlockedApp(bundleID: "com.hnc.Discord", name: "Discord"),
                                    BlockedApp(bundleID: "com.valvesoftware.steam", name: "Steam")])
        XCTAssertTrue(list.removeApp(bundleID: "COM.HNC.DISCORD"))
        XCTAssertEqual(list.apps.map(\.bundleID), ["com.valvesoftware.steam"])
        XCTAssertFalse(list.removeApp(bundleID: "com.nothere"))
    }

    func testBlockedBundleIDsPreservesOrder() {
        let list = BlockList(apps: [BlockedApp(bundleID: "com.valvesoftware.steam", name: "Steam"),
                                    BlockedApp(bundleID: "com.hnc.Discord", name: "Discord")])
        XCTAssertEqual(list.blockedBundleIDs(), ["com.valvesoftware.steam", "com.hnc.Discord"])
    }

    func testAppNameLookup() {
        let list = BlockList(apps: [BlockedApp(bundleID: "com.hnc.Discord", name: "Discord")])
        XCTAssertEqual(list.appName(for: "com.hnc.discord"), "Discord")
        XCTAssertNil(list.appName(for: "com.nothere"))
    }

    func testDecodingLegacyJSONWithoutAppsKeyDefaultsToEmpty() throws {
        let legacy = #"{"domains":["facebook.com"],"isBlocking":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(BlockList.self, from: legacy)
        XCTAssertEqual(decoded.domains, ["facebook.com"])
        XCTAssertTrue(decoded.isBlocking)
        XCTAssertEqual(decoded.apps, [])
    }

    func testCodableRoundTripIncludesApps() throws {
        let list = BlockList(domains: ["facebook.com"],
                             apps: [BlockedApp(bundleID: "com.hnc.Discord", name: "Discord")],
                             isBlocking: true)
        let data = try JSONEncoder().encode(list)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertTrue(json.contains("\"apps\""))
        XCTAssertTrue(json.contains("com.hnc.Discord"))
        XCTAssertEqual(try JSONDecoder().decode(BlockList.self, from: data), list)
    }

    func testStatsKeyIsNamespacedAndLowercased() {
        XCTAssertEqual(BlockedApp.statsKey(for: "com.hnc.Discord"), "app:com.hnc.discord")
    }
}
