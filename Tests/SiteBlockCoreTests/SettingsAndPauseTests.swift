import XCTest
@testable import SiteBlockCore

private final class FakeHosts: HostsApplying, @unchecked Sendable {
    var live: [String] = []
    var applied: [[String]] = []
    func apply(_ hosts: [String]) async throws { applied.append(hosts); live = hosts }
    func removeBlock() async throws { live = [] }
    func currentManagedHosts() async throws -> [String] { live }
}

private final class FakeAppBlocker: AppBlockApplying, @unchecked Sendable {
    var live: [String] = []
    var applied: [[String]] = []
    func applyBlockedApps(_ bundleIDs: [String]) async throws { applied.append(bundleIDs); live = bundleIDs }
    func currentBlockedApps() async throws -> [String] { live }
}

private final class FakeAuth: PasswordAuthenticating, @unchecked Sendable {
    func authenticate(reason: String) async -> Bool { true }
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

// MARK: - FrictionSettings

final class FrictionSettingsTests: XCTestCase {

    func testDefaultsAreTheMinimums() {
        let s = FrictionSettings()
        XCTAssertEqual(s.cooldownMinutes, 5)
        XCTAssertEqual(s.windowMinutes, 2)
        XCTAssertEqual(s.cooldown, 300)
        XCTAssertEqual(s.window, 120)
    }

    func testValuesAreClampedToTheirRanges() {
        XCTAssertEqual(FrictionSettings(cooldownMinutes: 1, windowMinutes: 0),
                       FrictionSettings(cooldownMinutes: 5, windowMinutes: 2), "never looser than 5/2")
        XCTAssertEqual(FrictionSettings(cooldownMinutes: 999, windowMinutes: 999),
                       FrictionSettings(cooldownMinutes: 120, windowMinutes: 30))
        XCTAssertEqual(FrictionSettings(cooldownMinutes: 15, windowMinutes: 4).cooldown, 900)
    }

    func testDecodingClampsAHandEditedFile() throws {
        let json = #"{"cooldownMinutes": 0, "windowMinutes": 1}"#.data(using: .utf8)!
        XCTAssertEqual(try JSONDecoder().decode(FrictionSettings.self, from: json), FrictionSettings())
    }
}

// MARK: - BlockList pause + settings persistence

final class BlockListPauseTests: XCTestCase {

    func testPausedItemsAreLeftOutOfEnforcement() {
        var list = BlockList()
        list.add("facebook.com"); list.add("x.com")
        list.addApp(bundleID: "com.valvesoftware.steam", name: "Steam")
        list.addApp(bundleID: "com.hnc.Discord", name: "Discord")

        XCTAssertTrue(list.setDomainPaused("https://www.facebook.com/feed", true), "matches the canonical form")
        XCTAssertTrue(list.setAppPaused("COM.VALVESOFTWARE.STEAM", true), "bundle ids are case-insensitive")

        XCTAssertFalse(list.allBlockedHosts().contains("facebook.com"))
        XCTAssertTrue(list.allBlockedHosts().contains("x.com"))
        XCTAssertEqual(list.blockedBundleIDs(), ["com.hnc.Discord"])
        XCTAssertEqual(list.domains.count, 2, "paused items stay on the list")
        XCTAssertTrue(list.isAppPaused("com.valvesoftware.steam"))
    }

    func testPausingUnknownOrAlreadyPausedItemsIsANoOp() {
        var list = BlockList()
        list.add("facebook.com")
        XCTAssertFalse(list.setDomainPaused("nothere.com", true))
        XCTAssertFalse(list.setAppPaused("com.nothere", true))
        XCTAssertTrue(list.setDomainPaused("facebook.com", true))
        XCTAssertFalse(list.setDomainPaused("facebook.com", true))
        XCTAssertTrue(list.setDomainPaused("facebook.com", false))
        XCTAssertFalse(list.setDomainPaused("facebook.com", false))
    }

    func testRemovingAnItemForgetsItsPause() {
        var list = BlockList()
        list.add("facebook.com")
        list.addApp(bundleID: "com.hnc.Discord", name: "Discord")
        list.setDomainPaused("facebook.com", true)
        list.setAppPaused("com.hnc.Discord", true)
        list.remove("facebook.com")
        list.removeApp(bundleID: "com.hnc.Discord")
        list.add("facebook.com")
        list.addApp(bundleID: "com.hnc.Discord", name: "Discord")
        XCTAssertFalse(list.isDomainPaused("facebook.com"), "re-adding starts blocked")
        XCTAssertFalse(list.isAppPaused("com.hnc.Discord"))
    }

    func testPauseAndSettingsRoundTripThroughTheStore() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-pause-\(UUID().uuidString)/blocklist.json")
        let store = BlockListStore(url: url)
        var list = BlockList(settings: FrictionSettings(cooldownMinutes: 20, windowMinutes: 5))
        list.add("facebook.com")
        list.addApp(bundleID: "com.hnc.Discord", name: "Discord")
        list.setDomainPaused("facebook.com", true)
        list.setAppPaused("com.hnc.Discord", true)
        try store.save(list)
        XCTAssertEqual(try store.load(), list)
    }

    func testOldFilesWithoutPauseOrSettingsStillLoad() throws {
        let json = #"{"domains": ["facebook.com"], "isBlocking": true}"#.data(using: .utf8)!
        let list = try JSONDecoder().decode(BlockList.self, from: json)
        XCTAssertEqual(list.settings, FrictionSettings())
        XCTAssertEqual(list.allBlockedHosts().first, "facebook.com")
    }

    func testStalePauseEntriesAreDroppedOnLoad() throws {
        let json = #"{"domains": ["x.com"], "pausedDomains": ["gone.com", "x.com"], "pausedApps": ["com.gone"]}"#
            .data(using: .utf8)!
        let list = try JSONDecoder().decode(BlockList.self, from: json)
        XCTAssertEqual(list.pausedDomains, ["x.com"])
        XCTAssertEqual(list.pausedApps, [])
    }
}

// MARK: - AppModel

@MainActor
final class AppModelSettingsAndPauseTests: XCTestCase {

    let t0 = Date(timeIntervalSinceReferenceDate: 4_000_000)
    let steam = "com.valvesoftware.steam"

    private func makeModel(url: URL? = nil) -> (AppModel, FakeHosts, FakeAppBlocker, TestClock) {
        let url = url ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-settings-\(UUID().uuidString)/blocklist.json")
        let hosts = FakeHosts(), apps = FakeAppBlocker(), clock = TestClock(t0)
        let model = AppModel(store: BlockListStore(url: url), hosts: hosts, auth: FakeAuth(),
                             apps: apps, clock: { clock.now })
        return (model, hosts, apps, clock)
    }

    // settings

    func testSettingsChangeWhileOffAndDriveTheGate() async {
        let (model, _, _, clock) = makeModel()
        model.setCooldownMinutes(10)
        model.setWindowMinutes(3)
        XCTAssertEqual(model.settings, FrictionSettings(cooldownMinutes: 10, windowMinutes: 3))

        await model.turnBlockingOn()
        model.requestTurnOff()
        clock.advance(5 * 60); model.tick()
        XCTAssertFalse(model.canConfirm, "the old 5-minute wait no longer opens the window")
        clock.advance(5 * 60); model.tick()
        XCTAssertTrue(model.canConfirm)
        clock.advance(3 * 60 + 1); model.tick()
        XCTAssertNil(model.pending, "3-minute window closed")
    }

    func testSettingsCannotGoBelowTheMinimum() {
        let (model, _, _, _) = makeModel()
        model.setCooldownMinutes(1)
        model.setWindowMinutes(1)
        XCTAssertEqual(model.settings, FrictionSettings(cooldownMinutes: 5, windowMinutes: 2))
    }

    func testSettingsAreLockedWhileBlockingIsOn() async {
        let (model, _, _, _) = makeModel()
        await model.turnBlockingOn()
        XCTAssertFalse(model.canChangeSettings)
        model.setCooldownMinutes(60)
        model.setWindowMinutes(10)
        XCTAssertEqual(model.settings, FrictionSettings())
    }

    func testSettingsAreLockedWhileAWeakenIsPending() async {
        let (model, _, _, _) = makeModel()
        await model.addDomain("facebook.com")
        model.requestRemove("facebook.com")
        XCTAssertFalse(model.canChangeSettings)
        model.setCooldownMinutes(60)
        XCTAssertEqual(model.settings.cooldownMinutes, 5)
        XCTAssertEqual(model.pending, .removeDomain("facebook.com"), "timer untouched")
    }

    func testSettingsSurviveARelaunch() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-settings-\(UUID().uuidString)/blocklist.json")
        let (first, _, _, _) = makeModel(url: url)
        first.setCooldownMinutes(30)
        let (second, _, _, _) = makeModel(url: url)
        XCTAssertEqual(second.settings.cooldownMinutes, 30)
    }

    func testRelaunchedGateUsesTheSavedLengths() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-settings-\(UUID().uuidString)/blocklist.json")
        let (first, _, _, _) = makeModel(url: url)
        first.setCooldownMinutes(30)
        await first.addDomain("facebook.com")

        let (second, _, _, clock) = makeModel(url: url)
        second.requestRemove("facebook.com")
        clock.advance(29 * 60); second.tick()
        XCTAssertFalse(second.canConfirm)
        clock.advance(60); second.tick()
        XCTAssertTrue(second.canConfirm)
    }

    // pause

    func testPauseWhileOffLeavesItemOutWhenTurnedOn() async {
        let (model, hosts, apps, _) = makeModel()
        await model.addDomain("facebook.com")
        await model.addDomain("x.com")
        await model.addApp(bundleID: steam, name: "Steam")
        model.pauseDomain("facebook.com")
        model.pauseApp(steam)

        await model.turnBlockingOn()
        XCTAssertFalse(hosts.live.contains("facebook.com"))
        XCTAssertTrue(hosts.live.contains("x.com"))
        XCTAssertEqual(apps.live, [])
        XCTAssertEqual(model.blockingStatus, .active, "a paused item is not an enforcement gap")
    }

    func testPauseIsUnavailableWhileBlockingIsOn() async {
        let (model, hosts, apps, _) = makeModel()
        await model.addDomain("facebook.com")
        await model.addApp(bundleID: steam, name: "Steam")
        await model.turnBlockingOn()
        XCTAssertFalse(model.canPause)
        model.pauseDomain("facebook.com")
        model.pauseApp(steam)
        XCTAssertFalse(model.isDomainPaused("facebook.com"))
        XCTAssertFalse(model.isAppPaused(steam))
        XCTAssertTrue(hosts.live.contains("facebook.com"))
        XCTAssertEqual(apps.live, [steam])
    }

    func testResumeWhileOnIsInstantAndTouchesOnlyItsHalf() async {
        let (model, hosts, apps, _) = makeModel()
        await model.addDomain("facebook.com")
        await model.addApp(bundleID: steam, name: "Steam")
        model.pauseDomain("facebook.com")
        model.pauseApp(steam)
        await model.turnBlockingOn()
        let hostWrites = hosts.applied.count, appWrites = apps.applied.count

        await model.resumeApp(steam)
        XCTAssertEqual(apps.live, [steam])
        XCTAssertEqual(hosts.applied.count, hostWrites, "app resume leaves /etc/hosts alone")

        await model.resumeDomain("facebook.com")
        XCTAssertTrue(hosts.live.contains("facebook.com"))
        XCTAssertEqual(apps.applied.count, appWrites + 1, "domain resume doesn't re-push apps")
        XCTAssertEqual(model.blockingStatus, .active)
    }

    func testResumeWhileOffDoesNotTouchTheSystem() async {
        let (model, hosts, apps, _) = makeModel()
        await model.addDomain("facebook.com")
        model.pauseDomain("facebook.com")
        await model.resumeDomain("facebook.com")
        XCTAssertFalse(model.isDomainPaused("facebook.com"))
        XCTAssertTrue(hosts.applied.isEmpty)
        XCTAssertTrue(apps.applied.isEmpty)
    }

    func testVerifyWithPausedItemsStaysActive() async {
        let (model, _, _, _) = makeModel()
        await model.addDomain("facebook.com")
        await model.addDomain("x.com")
        model.pauseDomain("facebook.com")
        await model.turnBlockingOn()
        await model.verifyEnforcement()
        XCTAssertEqual(model.blockingStatus, .active)
    }
}
