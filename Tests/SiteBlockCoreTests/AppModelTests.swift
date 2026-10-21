import XCTest
@testable import SiteBlockCore

private final class FakeHosts: HostsApplying, @unchecked Sendable {
    var applied: [[String]] = []
    var removeCount = 0
    /// What's actually "live" in the system — what `currentManagedHosts()` reports back.
    var live: [String] = []
    /// Simulate the helper being unreachable (e.g. not approved): `apply` throws.
    var applyError: Error?
    /// Simulate the insidious case: `apply` returns success but nothing lands in the system
    /// (the unapproved helper never ran). Verification must still flag this as not-enforced.
    var dropWrites = false
    func apply(_ hosts: [String]) async throws {
        if let applyError { throw applyError }
        applied.append(hosts)
        if !dropWrites { live = hosts }
    }
    func removeBlock() async throws {
        if let applyError { throw applyError }
        removeCount += 1
        live = []
    }
    func currentManagedHosts() async throws -> [String] { live }
}

private struct FakeHostsError: Error {}

private final class FakeStatsProvider: BlockStatsProviding, @unchecked Sendable {
    var stats = BlockStats()
    func fetchBlockStats() async throws -> BlockStats { stats }
}

private final class FakeNotifier: BlockNotifying, @unchecked Sendable {
    var notifications: [(domain: String, count: Int)] = []
    func notifyBlocked(domain: String, count: Int) async {
        notifications.append((domain, count))
    }
}

private final class FakeAuth: PasswordAuthenticating, @unchecked Sendable {
    var succeed = true
    var calls = 0
    /// Optionally advance the clock while "the prompt is up" to simulate a slow auth.
    var onAuthenticate: (() -> Void)?
    func authenticate(reason: String) async -> Bool {
        calls += 1
        onAuthenticate?()
        return succeed
    }
}

/// A controllable clock for deterministic time in tests.
private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

@MainActor
final class AppModelTests: XCTestCase {

    let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func makeModel() -> (AppModel, FakeHosts, FakeAuth, TestClock) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-app-\(UUID().uuidString)/blocklist.json")
        let hosts = FakeHosts()
        let auth = FakeAuth()
        let clock = TestClock(t0)
        let model = AppModel(store: BlockListStore(url: url), hosts: hosts, auth: auth,
                             clock: { clock.now })
        return (model, hosts, auth, clock)
    }

    // MARK: strengthen — instant

    func testAddDomainIsInstantAndAppliesWhenBlocking() async {
        let (model, hosts, _, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        XCTAssertEqual(model.domains, ["facebook.com"])
        XCTAssertNil(model.pending)
        XCTAssertTrue(hosts.applied.last?.contains("facebook.com") ?? false)
    }

    func testAddInvalidDomainSetsStatusAndDoesNotAdd() async {
        let (model, _, _, _) = makeModel()
        await model.addDomain("not a domain")
        XCTAssertTrue(model.domains.isEmpty)
        XCTAssertNotNil(model.status)
    }

    func testTurnOnIsInstant() async {
        let (model, hosts, _, _) = makeModel()
        await model.turnBlockingOn()
        XCTAssertTrue(model.isBlocking)
        XCTAssertNil(model.pending)
        XCTAssertEqual(hosts.applied.count, 1)
    }

    // MARK: weaken — gated

    func testTurnOffRequiresCooldownThenWindowThenAuth() async {
        let (model, hosts, auth, clock) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")

        model.requestTurnOff()
        XCTAssertEqual(model.pending, .turnOff)

        // Too early — inside cooldown, cannot confirm.
        clock.advance(120)
        model.tick()
        XCTAssertFalse(model.canConfirm)
        let early = await model.confirmPending()
        XCTAssertFalse(early)
        XCTAssertTrue(model.isBlocking, "still blocking after failed early confirm")
        XCTAssertEqual(auth.calls, 0, "no password prompt during cooldown")

        // Window open — confirm with successful auth.
        clock.now = t0.addingTimeInterval(330)
        model.tick()
        XCTAssertTrue(model.canConfirm)
        let ok = await model.confirmPending()
        XCTAssertTrue(ok)
        XCTAssertFalse(model.isBlocking)
        XCTAssertEqual(auth.calls, 1)
        XCTAssertEqual(hosts.removeCount, 1)
        XCTAssertNil(model.pending)
    }

    func testTurnOffFailsIfAuthCancelled() async {
        let (model, _, auth, clock) = makeModel()
        auth.succeed = false
        await model.turnBlockingOn()

        model.requestTurnOff()
        clock.now = t0.addingTimeInterval(330)
        model.tick()
        let ok = await model.confirmPending()
        XCTAssertFalse(ok)
        XCTAssertTrue(model.isBlocking, "auth cancelled → still blocking")
    }

    func testSlowAuthThatOutlastsWindowIsRejected() async {
        // Copilot finding: the window must be re-checked AFTER auth returns. Simulate an auth
        // prompt that succeeds but only after the 2-minute window has closed.
        let (model, hosts, auth, clock) = makeModel()
        await model.turnBlockingOn()
        model.requestTurnOff()
        clock.now = t0.addingTimeInterval(330) // window open
        model.tick()
        XCTAssertTrue(model.canConfirm)
        // While the prompt is up, real time advances past the window end (300+120 = 420).
        auth.onAuthenticate = { clock.now = self.t0.addingTimeInterval(500) }

        let ok = await model.confirmPending()
        XCTAssertFalse(ok, "expired-during-auth window must not confirm")
        XCTAssertTrue(model.isBlocking, "still blocking")
        XCTAssertNil(model.pending)
    }

    func testStartingTurnOffMidRemovalIsIgnored() async {
        // Friction-bypass guard: while a domain removal is cooling, hitting "turn off" must not
        // hijack the in-flight timer.
        let (model, _, _, clock) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")

        model.requestRemove("facebook.com")
        // Its cooldown has already elapsed (armed).
        clock.now = t0.addingTimeInterval(330)
        model.tick()

        // Attempt to turn off now — must be ignored (removal still the pending action).
        model.requestTurnOff()
        XCTAssertEqual(model.pending, .removeDomain("facebook.com"))

        let ok = await model.confirmPending()
        XCTAssertTrue(ok)
        XCTAssertTrue(model.isBlocking, "blocking stays on — only the domain was removed")
        XCTAssertEqual(model.domains, [])
    }

    func testCancelDuringAuthDoesNotApplyStaleAction() async {
        // Reentrancy guard: if the pending action changes while the auth prompt is up (user
        // cancels mid-prompt), the resolving confirm must not apply the old action. The auth hook
        // runs on the main actor synchronously inside `confirmPending`'s await point.
        let (model, hosts, auth, clock) = makeModel()
        await model.turnBlockingOn()
        model.requestTurnOff()
        clock.now = t0.addingTimeInterval(330)
        model.tick()
        auth.onAuthenticate = { [weak model] in model?.cancelPending() } // user cancels mid-prompt

        let ok = await model.confirmPending()
        XCTAssertFalse(ok, "cancelled action must not apply")
        XCTAssertTrue(model.isBlocking)
        XCTAssertEqual(hosts.removeCount, 0)
    }

    func testExpiredWindowClearsPending() async {
        let (model, _, _, clock) = makeModel()
        await model.turnBlockingOn()
        model.requestTurnOff()
        clock.now = t0.addingTimeInterval(500) // past 300+120
        model.tick()
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.isBlocking)
    }

    func testRemoveDomainIsGated() async {
        let (model, hosts, _, clock) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        await model.addDomain("x.com")

        model.requestRemove("facebook.com")
        XCTAssertEqual(model.pending, .removeDomain("facebook.com"))
        clock.now = t0.addingTimeInterval(330)
        model.tick()
        let ok = await model.confirmPending()
        XCTAssertTrue(ok)
        XCTAssertEqual(model.domains, ["x.com"])
        XCTAssertTrue(hosts.applied.last?.contains("x.com") ?? false)
        XCTAssertFalse(hosts.applied.last?.contains("facebook.com") ?? true)
    }

    func testCancelPendingResetsTimer() async {
        let (model, _, _, clock) = makeModel()
        await model.turnBlockingOn()
        model.requestTurnOff()
        clock.advance(100)
        model.tick()
        model.cancelPending()
        XCTAssertNil(model.pending)
        XCTAssertNil(model.cooldownRemaining)
    }

    // MARK: enforcement verification (the "icon must not lie" fix)

    func testSuccessfulPushIsVerifiedActive() async {
        let (model, _, _, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        XCTAssertTrue(model.systemBlockVerified)
        XCTAssertEqual(model.blockingStatus, .active)
    }

    func testSilentApplyFailureIsReportedNotEnforced() async {
        // apply() "succeeds" but nothing lands in the system (unapproved helper never ran).
        let (model, hosts, _, _) = makeModel()
        hosts.dropWrites = true
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        XCTAssertTrue(model.isBlocking, "intent is still on")
        XCTAssertFalse(model.systemBlockVerified, "but nothing actually landed")
        XCTAssertEqual(model.blockingStatus, .notEnforced)
        XCTAssertNotNil(model.status, "the failure is surfaced, not swallowed")
    }

    func testThrowingApplyIsReportedNotEnforced() async {
        let (model, hosts, _, _) = makeModel()
        hosts.applyError = FakeHostsError()
        await model.turnBlockingOn()
        XCTAssertTrue(model.isBlocking)
        XCTAssertEqual(model.blockingStatus, .notEnforced)
        XCTAssertNotNil(model.status)
    }

    func testRetryEnforcementRecoversAfterApproval() async {
        // Fails first (helper not approved), then the user approves and hits Retry.
        let (model, hosts, _, _) = makeModel()
        hosts.applyError = FakeHostsError()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        XCTAssertEqual(model.blockingStatus, .notEnforced)

        hosts.applyError = nil // approval granted
        await model.retryEnforcement()
        XCTAssertEqual(model.blockingStatus, .active)
        XCTAssertTrue(model.systemBlockVerified)
        XCTAssertNil(model.status)
    }

    func testRetryEnforcementDoesNotDisturbPendingWeaken() async {
        let (model, hosts, _, clock) = makeModel()
        await model.turnBlockingOn()
        model.requestTurnOff()
        clock.advance(60)
        model.tick()
        XCTAssertEqual(model.pending, .turnOff)

        await model.retryEnforcement()
        XCTAssertEqual(model.pending, .turnOff, "retry must not clear an in-flight weaken")
        XCTAssertNotNil(model.cooldownRemaining)
    }

    func testTurnedOffIsStatusOff() async {
        let (model, _, _, clock) = makeModel()
        await model.turnBlockingOn()
        XCTAssertEqual(model.blockingStatus, .active)
        model.requestTurnOff()
        clock.now = t0.addingTimeInterval(330)
        model.tick()
        _ = await model.confirmPending()
        XCTAssertEqual(model.blockingStatus, .off)
        XCTAssertFalse(model.systemBlockVerified)
    }

    // MARK: runtime enforcement re-verification

    func testVerifyEnforcementSelfHealsWhenRegionStripped() async {
        let (model, hosts, _, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        XCTAssertEqual(model.blockingStatus, .active)

        // The block gets stripped behind our back (outside edit / another tool).
        hosts.live = []
        let appliesBefore = hosts.applied.count
        await model.verifyEnforcement()
        XCTAssertEqual(hosts.applied.count, appliesBefore + 1, "drift triggers an ungated re-push")
        XCTAssertEqual(model.blockingStatus, .active, "healed and re-verified")
    }

    func testVerifyEnforcementReportsNotEnforcedWhenHealFails() async {
        let (model, hosts, _, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        XCTAssertEqual(model.blockingStatus, .active)

        // Region stripped AND the helper has become unreachable — healing must fail loudly.
        hosts.live = []
        hosts.applyError = FakeHostsError()
        await model.verifyEnforcement()
        XCTAssertEqual(model.blockingStatus, .notEnforced)
        XCTAssertNotNil(model.status)
    }

    func testStaleExtraHostsFailVerification() async {
        // Verification requires exact equality: after a removal, a silently-failed write that
        // leaves the old (larger) region live must not pass as "the removal landed".
        let (model, hosts, _, clock) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        await model.addDomain("x.com")
        XCTAssertEqual(model.blockingStatus, .active)

        // Remove x.com through the gate, but the write never lands (old region stays live).
        hosts.dropWrites = true
        model.requestRemove("x.com")
        clock.now = t0.addingTimeInterval(330)
        model.tick()
        let ok = await model.confirmPending()
        XCTAssertTrue(ok, "the gated action itself completes")
        XCTAssertEqual(model.blockingStatus, .notEnforced,
                       "but the live superset must fail verification, not pass as a subset match")
    }

    func testVerifyEnforcementHealsAwayStaleExtraHosts() async {
        let (model, hosts, _, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")

        // Drift: something re-adds an extra host to the live region.
        hosts.live.append("stale.example.com")
        await model.verifyEnforcement()
        XCTAssertEqual(model.blockingStatus, .active)
        XCTAssertFalse(hosts.live.contains("stale.example.com"), "heal re-applied the exact set")
    }

    func testVerifyEnforcementIsQuietWhenAllGood() async {
        let (model, hosts, _, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        let appliesBefore = hosts.applied.count
        await model.verifyEnforcement()
        XCTAssertEqual(hosts.applied.count, appliesBefore, "no drift → no re-push")
        XCTAssertEqual(model.blockingStatus, .active)
    }

    func testVerifyEnforcementNoOpWhenBlockingOff() async {
        let (model, hosts, _, _) = makeModel()
        await model.verifyEnforcement()
        XCTAssertTrue(hosts.applied.isEmpty)
        XCTAssertEqual(model.blockingStatus, .off)
    }

    func testVerifyEnforcementDoesNotDisturbPendingWeaken() async {
        let (model, hosts, _, clock) = makeModel()
        await model.turnBlockingOn()
        model.requestTurnOff()
        clock.advance(60)
        model.tick()
        hosts.live = [] // drift while a weaken is pending
        await model.verifyEnforcement()
        XCTAssertEqual(model.pending, .turnOff, "healing must not clear the in-flight weaken")
        XCTAssertNotNil(model.cooldownRemaining)
        XCTAssertEqual(model.blockingStatus, .active, "and still heals")
    }

    // MARK: block statistics + notifications

    private func makeStatsModel() -> (AppModel, FakeStatsProvider, FakeNotifier, TestClock) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-stats-\(UUID().uuidString)/blocklist.json")
        let provider = FakeStatsProvider()
        let notifier = FakeNotifier()
        let clock = TestClock(t0)
        let model = AppModel(store: BlockListStore(url: url), hosts: FakeHosts(), auth: FakeAuth(),
                             statsProvider: provider, notifier: notifier,
                             notificationInterval: 60,
                             clock: { clock.now })
        return (model, provider, notifier, clock)
    }

    func testBlockedCountAggregatesSubdomains() async {
        let (model, provider, _, _) = makeStatsModel()
        await model.addDomain("facebook.com")
        provider.stats = BlockStats(counts: [
            "facebook.com": 2, "www.facebook.com": 3, "m.facebook.com": 1, "x.com": 7,
        ])
        await model.refreshStats()
        XCTAssertEqual(model.blockedCount(for: "facebook.com"), 6, "domain + its subdomains")
        XCTAssertEqual(model.blockStats.total, 13, "raw total is unfiltered")
    }

    func testFirstRefreshBaselinesWithoutNotifying() async {
        // Counts accrued before this launch must not fire a notification storm on startup.
        let (model, provider, notifier, _) = makeStatsModel()
        await model.addDomain("facebook.com")
        provider.stats = BlockStats(counts: ["facebook.com": 42])
        await model.refreshStats()
        XCTAssertTrue(notifier.notifications.isEmpty, "baseline fetch is silent")
        XCTAssertEqual(model.blockedCount(for: "facebook.com"), 42, "but counts still display")
    }

    func testIncreaseAfterBaselineNotifiesWithAggregatedCount() async {
        let (model, provider, notifier, _) = makeStatsModel()
        await model.addDomain("facebook.com")
        provider.stats = BlockStats(counts: ["facebook.com": 1])
        await model.refreshStats() // baseline

        provider.stats = BlockStats(counts: ["facebook.com": 1, "www.facebook.com": 2])
        await model.refreshStats()
        XCTAssertEqual(notifier.notifications.count, 1)
        XCTAssertEqual(notifier.notifications.first?.domain, "facebook.com")
        XCTAssertEqual(notifier.notifications.first?.count, 3, "aggregated across subdomains")
    }

    func testNotificationsAreRateLimitedPerDomain() async {
        let (model, provider, notifier, clock) = makeStatsModel()
        await model.addDomain("facebook.com")
        provider.stats = BlockStats(counts: ["facebook.com": 1])
        await model.refreshStats() // baseline

        provider.stats = BlockStats(counts: ["facebook.com": 2])
        await model.refreshStats() // notifies
        provider.stats = BlockStats(counts: ["facebook.com": 3])
        await model.refreshStats() // within 60s — suppressed
        XCTAssertEqual(notifier.notifications.count, 1, "second increase inside the interval is quiet")

        clock.advance(61)
        provider.stats = BlockStats(counts: ["facebook.com": 4])
        await model.refreshStats() // interval elapsed — notifies again
        XCTAssertEqual(notifier.notifications.count, 2)
        XCTAssertEqual(notifier.notifications.last?.count, 4)
    }

    func testUnchangedCountsStayQuiet() async {
        let (model, provider, notifier, _) = makeStatsModel()
        await model.addDomain("facebook.com")
        provider.stats = BlockStats(counts: ["facebook.com": 5])
        await model.refreshStats() // baseline
        await model.refreshStats() // same counts
        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    func testRefreshWithoutProviderIsANoOp() async {
        let (model, _, _, _) = makeModel() // no statsProvider
        await model.refreshStats()
        XCTAssertEqual(model.blockStats.total, 0)
    }

    // MARK: lifecycle

    func testReconcileOnLaunchResetsTimerAndAppliesBlocking() async {
        let (model, hosts, _, clock) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        model.requestTurnOff()
        clock.now = t0.addingTimeInterval(310) // armed
        model.tick()

        await model.reconcileOnLaunch()
        XCTAssertNil(model.pending, "pending timer never survives a relaunch")
        XCTAssertTrue(model.isBlocking)
        XCTAssertTrue(hosts.applied.last?.contains("facebook.com") ?? false)
    }
}
