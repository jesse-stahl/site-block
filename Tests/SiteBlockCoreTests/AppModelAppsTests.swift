import XCTest
@testable import SiteBlockCore

private final class FakeHosts: HostsApplying, @unchecked Sendable {
    var live: [String] = []
    var applied: [[String]] = []
    var removeError: Error?
    func apply(_ hosts: [String]) async throws { applied.append(hosts); live = hosts }
    func removeBlock() async throws {
        if let removeError { throw removeError }
        live = []
    }
    func currentManagedHosts() async throws -> [String] { live }
}

private final class FakeAppBlocker: AppBlockApplying, @unchecked Sendable {
    var applied: [[String]] = []
    var live: [String] = []
    var applyError: Error?
    var dropWrites = false
    func applyBlockedApps(_ bundleIDs: [String]) async throws {
        if let applyError { throw applyError }
        applied.append(bundleIDs)
        if !dropWrites { live = bundleIDs }
    }
    func currentBlockedApps() async throws -> [String] { live }
}

private struct FakeError: Error {}

private final class FakeAuth: PasswordAuthenticating, @unchecked Sendable {
    var succeed = true
    var reasons: [String] = []
    func authenticate(reason: String) async -> Bool { reasons.append(reason); return succeed }
}

private final class FakeStatsProvider: BlockStatsProviding, @unchecked Sendable {
    var stats = BlockStats()
    func fetchBlockStats() async throws -> BlockStats { stats }
}

private final class FakeNotifier: BlockNotifying, @unchecked Sendable {
    var notifications: [(domain: String, count: Int)] = []
    func notifyBlocked(domain: String, count: Int) async { notifications.append((domain, count)) }
}

private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

@MainActor
final class AppModelAppsTests: XCTestCase {

    let t0 = Date(timeIntervalSinceReferenceDate: 3_000_000)
    let discord = "com.hnc.Discord"

    private func makeModel() -> (AppModel, FakeHosts, FakeAppBlocker, FakeAuth, FakeStatsProvider, FakeNotifier, TestClock) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-apps-\(UUID().uuidString)/blocklist.json")
        let hosts = FakeHosts(), apps = FakeAppBlocker(), auth = FakeAuth()
        let stats = FakeStatsProvider(), notifier = FakeNotifier(), clock = TestClock(t0)
        let model = AppModel(store: BlockListStore(url: url), hosts: hosts, auth: auth,
                             apps: apps, statsProvider: stats, notifier: notifier,
                             friction: FrictionMachine(cooldown: 300, window: 120),
                             notificationInterval: 60, clock: { clock.now })
        return (model, hosts, apps, auth, stats, notifier, clock)
    }

    // MARK: strengthen

    func testAddAppIsInstantAndAppliesWhenBlocking() async {
        let (model, _, apps, _, _, _, _) = makeModel()
        await model.turnBlockingOn()
        await model.addApp(bundleID: discord, name: "Discord")
        XCTAssertEqual(model.apps.map(\.bundleID), [discord])
        XCTAssertEqual(apps.applied.last, [discord])
        XCTAssertEqual(model.blockingStatus, .active)
    }

    func testAddAppWhileOffDoesNotTouchSystem() async {
        let (model, _, apps, _, _, _, _) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        XCTAssertTrue(apps.applied.isEmpty)
        XCTAssertEqual(model.blockingStatus, .off)
    }

    func testAddInvalidAppSetsStatus() async {
        let (model, _, _, _, _, _, _) = makeModel()
        await model.addApp(bundleID: "  ", name: "X")
        XCTAssertNotNil(model.status)
        XCTAssertTrue(model.apps.isEmpty)
    }

    func testTurnOnPushesAppsAndHosts() async {
        let (model, hosts, apps, _, _, _, _) = makeModel()
        await model.addDomain("facebook.com")
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        XCTAssertEqual(apps.live, [discord])
        XCTAssertTrue(hosts.live.contains("facebook.com"))
        XCTAssertEqual(model.blockingStatus, .active)
    }

    // MARK: verification — both halves must land

    func testDroppedAppWriteIsNotEnforced() async {
        let (model, _, apps, _, _, _, _) = makeModel()
        apps.dropWrites = true
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        XCTAssertEqual(model.blockingStatus, .notEnforced)
    }

    func testThrowingAppApplyIsNotEnforced() async {
        let (model, _, apps, _, _, _, _) = makeModel()
        apps.applyError = FakeError()
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        XCTAssertEqual(model.blockingStatus, .notEnforced)
        XCTAssertNotNil(model.status)
    }

    func testVerifyEnforcementSelfHealsStrippedApps() async {
        let (model, _, apps, _, _, _, _) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        apps.live = []                            // helper restarted with an empty set
        await model.verifyEnforcement()
        XCTAssertEqual(apps.live, [discord])
        XCTAssertEqual(model.blockingStatus, .active)
    }

    func testVerifyEnforcementIsQuietWhenAppsMatch() async {
        let (model, _, apps, _, _, _, _) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        let before = apps.applied.count
        await model.verifyEnforcement()
        XCTAssertEqual(apps.applied.count, before)
    }

    func testTurnOffClearsApps() async {
        let (model, _, apps, auth, _, _, clock) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        model.requestTurnOff()
        clock.advance(300); model.tick()
        auth.succeed = true
        let turnedOff = await model.confirmPending()
        XCTAssertTrue(turnedOff)
        XCTAssertEqual(apps.live, [])
        XCTAssertEqual(model.blockingStatus, .off)
    }

    func testTurnOffClearsAppsEvenWhenHostsRemovalFails() async {
        // A failed hosts removal must never leave root killing the user's apps behind an "off"
        // padlock — each half of the removal is attempted independently.
        let (model, hosts, apps, _, _, _, clock) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        hosts.removeError = FakeError()
        model.requestTurnOff()
        clock.advance(300); model.tick()
        _ = await model.confirmPending()
        XCTAssertEqual(model.blockingStatus, .off)
        XCTAssertEqual(apps.live, [], "app half cleared despite the hosts failure")
        XCTAssertNotNil(model.status, "the hosts failure is still surfaced")
    }

    func testVerifyEnforcementWhileOffClearsAStaleHelperAppSet() async {
        // The helper still holds a set (a turn-off whose XPC call was dropped): the periodic
        // check reconciles to the OFF intent instead of ignoring it.
        let (model, _, apps, _, _, _, _) = makeModel()
        apps.live = [discord]
        await model.verifyEnforcement()
        XCTAssertEqual(apps.live, [])
        XCTAssertEqual(model.blockingStatus, .off)
    }

    func testStrippedAppsHealWithoutRewritingHosts() async {
        // Only the drifted half is re-applied: a stuck app half must not cause a privileged
        // /etc/hosts rewrite on every 5-second check.
        let (model, hosts, apps, _, _, _, _) = makeModel()
        await model.addDomain("facebook.com")
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        let hostsWrites = hosts.applied.count
        apps.live = []
        await model.verifyEnforcement()
        XCTAssertEqual(apps.live, [discord])
        XCTAssertEqual(hosts.applied.count, hostsWrites, "hosts matched → not rewritten")
        XCTAssertEqual(model.blockingStatus, .active)
    }

    // MARK: weaken — remove app is gated

    func testRemoveAppRequiresCooldownWindowAndAuth() async {
        let (model, _, apps, auth, _, _, clock) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()

        model.requestRemoveApp(discord)
        XCTAssertEqual(model.pending, .removeApp(discord))
        let early = await model.confirmPending()
        XCTAssertFalse(early, "still cooling down")
        XCTAssertEqual(model.apps.count, 1)

        clock.advance(300); model.tick()
        XCTAssertTrue(model.canConfirm)
        let removed = await model.confirmPending()
        XCTAssertTrue(removed)
        XCTAssertEqual(auth.reasons.last, "remove Discord from your block list")
        XCTAssertTrue(model.apps.isEmpty)
        XCTAssertEqual(apps.live, [], "removal pushed to the helper")
        XCTAssertNil(model.pending)
    }

    func testRemoveAppFailsWhenAuthCancelled() async {
        let (model, _, _, auth, _, _, clock) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        model.requestRemoveApp(discord)
        clock.advance(300); model.tick()
        auth.succeed = false
        let confirmed = await model.confirmPending()
        XCTAssertFalse(confirmed)
        XCTAssertEqual(model.apps.count, 1)
        XCTAssertEqual(model.pending, .removeApp(discord), "still pending; user can retry inside the window")
    }

    func testRemoveUnknownAppOrWhileAnotherPendingIsIgnored() async {
        let (model, _, _, _, _, _, _) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        model.requestRemoveApp("com.nothere")
        XCTAssertNil(model.pending)
        model.requestTurnOff()                       // blocking is off → ignored, pending stays nil
        await model.turnBlockingOn()
        model.requestTurnOff()
        model.requestRemoveApp(discord)
        XCTAssertEqual(model.pending, .turnOff, "second weaken action must not hijack the timer")
    }

    func testRequestRemoveAppStoresTheCanonicalID() async {
        // The row compares against the listed casing; a differently-cased request must still
        // light up that row's pending UI.
        let (model, _, _, _, _, _, _) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        model.requestRemoveApp("COM.HNC.DISCORD")
        XCTAssertEqual(model.pending, .removeApp(discord))
        XCTAssertTrue(model.isAppBlocked("com.hnc.discord"))
        XCTAssertFalse(model.isAppBlocked("com.nothere"))
    }

    // MARK: stats + notifications

    func testBlockedCountForAppUsesNamespacedKey() async {
        let (model, _, _, _, stats, _, _) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        stats.stats = BlockStats(counts: ["app:com.hnc.discord": 4, "discord": 99])
        await model.refreshStats()
        XCTAssertEqual(model.blockedCount(forApp: discord), 4)
    }

    func testAppTalliesNeverFoldIntoADomainBySuffix() async {
        // "app:com.example.app" ends in ".example.app" — the site "example.app" must not count it.
        let (model, _, _, _, stats, notifier, _) = makeModel()
        await model.addDomain("example.app")
        await model.addApp(bundleID: "com.example.app", name: "Example")
        await model.refreshStats()
        stats.stats = BlockStats(counts: ["app:com.example.app": 3])
        await model.refreshStats()
        XCTAssertEqual(model.blockedCount(for: "example.app"), 0)
        XCTAssertEqual(model.blockedCount(forApp: "com.example.app"), 3)
        XCTAssertEqual(notifier.notifications.map(\.domain), ["Example"], "only the app is announced")
    }

    func testAppLaunchIncreaseNotifiesWithNameAndRateLimits() async {
        let (model, _, _, _, stats, notifier, clock) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        await model.refreshStats()                                   // baseline
        stats.stats = BlockStats(counts: ["app:com.hnc.discord": 1])
        await model.refreshStats()
        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertEqual(notifier.notifications.first?.domain, "Discord")
        XCTAssertEqual(notifier.notifications.first?.count, 1)

        stats.stats = BlockStats(counts: ["app:com.hnc.discord": 2])
        await model.refreshStats()
        XCTAssertEqual(notifier.notifications.count, 1, "rate-limited within 60s")
        clock.advance(61)
        stats.stats = BlockStats(counts: ["app:com.hnc.discord": 3])
        await model.refreshStats()
        XCTAssertEqual(notifier.notifications.count, 2)
    }

    // MARK: lifecycle / no app blocker

    func testReconcileOnLaunchPushesApps() async {
        let (model, _, apps, _, _, _, _) = makeModel()
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        apps.live = []
        await model.reconcileOnLaunch()
        XCTAssertEqual(apps.live, [discord])
    }

    func testWithoutAppBlockerHostsAloneDecideVerification() async {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-apps-\(UUID().uuidString)/blocklist.json")
        let model = AppModel(store: BlockListStore(url: url), hosts: FakeHosts(), auth: FakeAuth(),
                             friction: FrictionMachine(cooldown: 300, window: 120), clock: { self.t0 })
        await model.addApp(bundleID: discord, name: "Discord")
        await model.turnBlockingOn()
        XCTAssertEqual(model.blockingStatus, .active, "nil app blocker: legacy behaviour untouched")
    }
}
