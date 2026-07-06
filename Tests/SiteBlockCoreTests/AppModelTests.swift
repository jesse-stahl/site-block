import XCTest
@testable import SiteBlockCore

private final class FakeHosts: HostsApplying, @unchecked Sendable {
    var applied: [[String]] = []
    var removeCount = 0
    func apply(_ hosts: [String]) async throws { applied.append(hosts) }
    func removeBlock() async throws { removeCount += 1 }
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
                             friction: FrictionMachine(cooldown: 300, window: 120),
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
