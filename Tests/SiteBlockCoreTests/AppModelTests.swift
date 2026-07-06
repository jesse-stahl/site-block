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
    func authenticate(reason: String) async -> Bool { calls += 1; return succeed }
}

@MainActor
final class AppModelTests: XCTestCase {

    let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func makeModel() -> (AppModel, FakeHosts, FakeAuth) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-app-\(UUID().uuidString)/blocklist.json")
        let hosts = FakeHosts()
        let auth = FakeAuth()
        let model = AppModel(store: BlockListStore(url: url), hosts: hosts, auth: auth,
                             friction: FrictionMachine(cooldown: 300, window: 120), now: t0)
        return (model, hosts, auth)
    }

    // MARK: strengthen — instant

    func testAddDomainIsInstantAndAppliesWhenBlocking() async {
        let (model, hosts, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        XCTAssertEqual(model.domains, ["facebook.com"])
        // Applied to system without any friction/pending.
        XCTAssertNil(model.pending)
        XCTAssertTrue(hosts.applied.last?.contains("facebook.com") ?? false)
    }

    func testAddInvalidDomainSetsStatusAndDoesNotAdd() async {
        let (model, _, _) = makeModel()
        await model.addDomain("not a domain")
        XCTAssertTrue(model.domains.isEmpty)
        XCTAssertNotNil(model.status)
    }

    func testTurnOnIsInstant() async {
        let (model, hosts, _) = makeModel()
        await model.turnBlockingOn()
        XCTAssertTrue(model.isBlocking)
        XCTAssertNil(model.pending)
        XCTAssertEqual(hosts.applied.count, 1)
    }

    // MARK: weaken — gated

    func testTurnOffRequiresCooldownThenWindowThenAuth() async {
        let (model, hosts, auth) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")

        model.requestTurnOff()
        XCTAssertEqual(model.pending, .turnOff)

        // Too early — inside cooldown, cannot confirm.
        model.tick(now: t0.addingTimeInterval(120))
        XCTAssertFalse(model.canConfirm)
        let early = await model.confirmPending()
        XCTAssertFalse(early)
        XCTAssertTrue(model.isBlocking, "still blocking after failed early confirm")
        XCTAssertEqual(auth.calls, 0, "no password prompt during cooldown")

        // Window open — confirm with successful auth.
        model.tick(now: t0.addingTimeInterval(330))
        XCTAssertTrue(model.canConfirm)
        let ok = await model.confirmPending()
        XCTAssertTrue(ok)
        XCTAssertFalse(model.isBlocking)
        XCTAssertEqual(auth.calls, 1)
        XCTAssertEqual(hosts.removeCount, 1)
        XCTAssertNil(model.pending)
    }

    func testTurnOffFailsIfAuthCancelled() async {
        let (model, _, auth) = makeModel()
        auth.succeed = false
        await model.turnBlockingOn()

        model.requestTurnOff()
        model.tick(now: t0.addingTimeInterval(330))
        let ok = await model.confirmPending()
        XCTAssertFalse(ok)
        XCTAssertTrue(model.isBlocking, "auth cancelled → still blocking")
    }

    func testExpiredWindowClearsPending() async {
        let (model, _, _) = makeModel()
        await model.turnBlockingOn()
        model.requestTurnOff()
        model.tick(now: t0.addingTimeInterval(500)) // past 300+120
        XCTAssertNil(model.pending)
        XCTAssertTrue(model.isBlocking)
    }

    func testRemoveDomainIsGated() async {
        let (model, hosts, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        await model.addDomain("x.com")

        model.requestRemove("facebook.com")
        XCTAssertEqual(model.pending, .removeDomain("facebook.com"))
        model.tick(now: t0.addingTimeInterval(330))
        let ok = await model.confirmPending()
        XCTAssertTrue(ok)
        XCTAssertEqual(model.domains, ["x.com"])
        // System re-applied with the remaining domain only.
        XCTAssertTrue(hosts.applied.last?.contains("x.com") ?? false)
        XCTAssertFalse(hosts.applied.last?.contains("facebook.com") ?? true)
    }

    func testCancelPendingResetsTimer() async {
        let (model, _, _) = makeModel()
        await model.turnBlockingOn()
        model.requestTurnOff()
        model.tick(now: t0.addingTimeInterval(100))
        model.cancelPending()
        XCTAssertNil(model.pending)
        XCTAssertNil(model.cooldownRemaining)
    }

    // MARK: lifecycle

    func testReconcileOnLaunchResetsTimerAndAppliesBlocking() async {
        let (model, hosts, _) = makeModel()
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")
        model.requestTurnOff()
        model.tick(now: t0.addingTimeInterval(310)) // armed

        await model.reconcileOnLaunch()
        XCTAssertNil(model.pending, "pending timer never survives a relaunch")
        XCTAssertTrue(model.isBlocking)
        XCTAssertTrue(hosts.applied.last?.contains("facebook.com") ?? false)
    }
}
