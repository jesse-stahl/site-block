import XCTest
@testable import SiteBlockCore

private final class FakeProcesses: ProcessListing, @unchecked Sendable {
    var processes: [RunningProcess] = []
    func runningProcesses() -> [RunningProcess] { processes }
}

private final class FakeSignals: ProcessSignaling, @unchecked Sendable {
    var terminated: [Int32] = []
    var killed: [Int32] = []
    func terminate(pid: Int32) { terminated.append(pid) }
    func kill(pid: Int32) { killed.append(pid) }
}

final class AppBlockEnforcerTests: XCTestCase {

    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)
    let discordMain = RunningProcess(pid: 100, executablePath: "/Applications/Discord.app/Contents/MacOS/Discord")
    let discordHelper = RunningProcess(pid: 101, executablePath:
        "/Applications/Discord.app/Contents/Frameworks/Discord Helper (GPU).app/Contents/MacOS/Discord Helper (GPU)")
    let steam = RunningProcess(pid: 200, executablePath:
        "/Users/j/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/steam_osx")
    let safari = RunningProcess(pid: 300, executablePath: "/Applications/Safari.app/Contents/MacOS/Safari")
    let ssh = RunningProcess(pid: 400, executablePath: "/usr/bin/ssh")

    /// Bundle-ID lookup keyed by bundle ROOT (what `AppBundle.bundleRoot` returns).
    let ids: [String: String] = [
        "/Applications/Discord.app": "com.hnc.Discord",
        "/Users/j/Library/Application Support/Steam/Steam.AppBundle/Steam": "com.valvesoftware.steam",
        "/Applications/Safari.app": "com.apple.Safari",
    ]

    private func make(ownPID: Int32 = 1, protected: Set<String> = ["today.siteblock.SiteBlock"])
        -> (AppBlockEnforcer, FakeProcesses, FakeSignals) {
        let procs = FakeProcesses()
        let sigs = FakeSignals()
        let table = ids
        let enforcer = AppBlockEnforcer(processes: procs, signals: sigs,
                                        bundleIdentifier: { root in table[root] },
                                        forceKillAfter: 3, protectedBundleIDs: protected, ownPID: ownPID)
        return (enforcer, procs, sigs)
    }

    func testNothingHappensWithEmptyBlockedSet() {
        let (enforcer, procs, sigs) = make()
        procs.processes = [discordMain, steam]
        XCTAssertEqual(enforcer.sweep(now: t0), [])
        XCTAssertTrue(sigs.terminated.isEmpty)
    }

    func testMatchesEveryProcessInBundleCaseInsensitively() {
        let (enforcer, procs, sigs) = make()
        procs.processes = [discordMain, discordHelper, safari, ssh]
        enforcer.setBlockedBundleIDs(["COM.HNC.DISCORD"], now: t0)
        // Baseline sweep on apply: killed, but not counted as attempts.
        XCTAssertEqual(Set(sigs.terminated), [100, 101])
        XCTAssertEqual(enforcer.blockedBundleIDs, ["COM.HNC.DISCORD"], "reports exactly what was applied")
    }

    func testApplyingSetKillsAlreadyRunningWithoutCountingAttempt() {
        let (enforcer, procs, sigs) = make()
        procs.processes = [steam]
        enforcer.setBlockedBundleIDs(["com.valvesoftware.steam"], now: t0)
        XCTAssertEqual(sigs.terminated, [200])
        // Next regular sweep: same pid still there, no NEW attempt reported.
        XCTAssertEqual(enforcer.sweep(now: t0.addingTimeInterval(1)), [])
    }

    func testNewLaunchIsTerminatedAndReportedOnce() {
        let (enforcer, procs, sigs) = make()
        enforcer.setBlockedBundleIDs(["com.hnc.Discord"], now: t0)
        procs.processes = [discordMain, discordHelper]
        let attempts = enforcer.sweep(now: t0.addingTimeInterval(1))
        XCTAssertEqual(attempts, ["com.hnc.Discord"], "one attempt per bundle per sweep, not per pid")
        XCTAssertEqual(Set(sigs.terminated), [100, 101])
        // Still alive one second later: not re-terminated, not re-reported.
        XCTAssertEqual(enforcer.sweep(now: t0.addingTimeInterval(2)), [])
        XCTAssertEqual(sigs.terminated.count, 2)
        XCTAssertTrue(sigs.killed.isEmpty)
    }

    func testEscalatesToKillAfterGracePeriod() {
        let (enforcer, procs, sigs) = make()
        enforcer.setBlockedBundleIDs(["com.hnc.Discord"], now: t0)
        procs.processes = [discordMain]
        _ = enforcer.sweep(now: t0.addingTimeInterval(1))       // SIGTERM at t+1
        _ = enforcer.sweep(now: t0.addingTimeInterval(3.5))     // 2.5s later: still grace
        XCTAssertTrue(sigs.killed.isEmpty)
        _ = enforcer.sweep(now: t0.addingTimeInterval(4))       // 3s later: SIGKILL
        XCTAssertEqual(sigs.killed, [100])
        _ = enforcer.sweep(now: t0.addingTimeInterval(5))       // keeps killing while it lingers
        XCTAssertEqual(sigs.killed, [100, 100])
    }

    func testPidThatExitsIsForgottenSoRelaunchCountsAgain() {
        let (enforcer, procs, sigs) = make()
        enforcer.setBlockedBundleIDs(["com.hnc.Discord"], now: t0)
        procs.processes = [discordMain]
        XCTAssertEqual(enforcer.sweep(now: t0.addingTimeInterval(1)), ["com.hnc.Discord"])
        procs.processes = []                                    // it quit
        XCTAssertEqual(enforcer.sweep(now: t0.addingTimeInterval(2)), [])
        procs.processes = [discordMain]                         // relaunched (same pid reused)
        XCTAssertEqual(enforcer.sweep(now: t0.addingTimeInterval(3)), ["com.hnc.Discord"])
        XCTAssertEqual(sigs.terminated, [100, 100])
    }

    func testNeverSignalsOwnPidOrProtectedBundle() {
        let (enforcer, procs, sigs) = make(ownPID: 100, protected: ["com.apple.Safari"])
        procs.processes = [discordMain, safari]
        enforcer.setBlockedBundleIDs(["com.hnc.Discord", "com.apple.Safari"], now: t0)
        _ = enforcer.sweep(now: t0.addingTimeInterval(1))
        XCTAssertTrue(sigs.terminated.isEmpty)
        XCTAssertTrue(sigs.killed.isEmpty)
    }

    func testUnknownBundleIsNeverKilled() {
        let (enforcer, procs, sigs) = make()
        procs.processes = [RunningProcess(pid: 500, executablePath: "/Applications/Mystery.app/Contents/MacOS/M")]
        enforcer.setBlockedBundleIDs(["com.mystery"], now: t0)
        _ = enforcer.sweep(now: t0.addingTimeInterval(1))
        XCTAssertTrue(sigs.terminated.isEmpty, "no bundle id resolvable → do not act on a guess")
    }

    func testReapplyingIdenticalSetIsANoOp() {
        // Routine re-pushes from the app (adding a domain, a 5s re-verify) must not reset the
        // escalation clock, re-signal, or swallow an in-flight attempt via a silent baseline sweep.
        let (enforcer, procs, sigs) = make()
        XCTAssertTrue(enforcer.setBlockedBundleIDs(["com.hnc.Discord"], now: t0))
        procs.processes = [discordMain]
        XCTAssertEqual(enforcer.sweep(now: t0.addingTimeInterval(1)), ["com.hnc.Discord"])
        XCTAssertFalse(enforcer.setBlockedBundleIDs(["com.hnc.Discord"], now: t0.addingTimeInterval(2)),
                       "same set → nothing to do")
        XCTAssertEqual(sigs.terminated, [100], "not re-terminated by a no-op re-apply")
        _ = enforcer.sweep(now: t0.addingTimeInterval(4))
        XCTAssertEqual(sigs.killed, [100], "escalation clock kept running from the original SIGTERM")
        XCTAssertTrue(enforcer.setBlockedBundleIDs(["com.hnc.Discord", "com.valvesoftware.steam"], now: t0),
                      "a different set is applied")
    }

    func testFailedBundleLookupIsRetriedNextSweep() {
        // An app mid-self-update has no readable Info.plist for a moment; that must not disable
        // blocking for it until the helper restarts.
        var readable = false
        var lookups = 0
        let procs = FakeProcesses()
        let sigs = FakeSignals()
        let enforcer = AppBlockEnforcer(processes: procs, signals: sigs,
                                        bundleIdentifier: { _ in lookups += 1; return readable ? "com.hnc.Discord" : nil },
                                        forceKillAfter: 3, protectedBundleIDs: [], ownPID: 1)
        enforcer.setBlockedBundleIDs(["com.hnc.Discord"], now: t0)
        procs.processes = [discordMain]
        XCTAssertEqual(enforcer.sweep(now: t0.addingTimeInterval(1)), [])
        readable = true
        XCTAssertEqual(enforcer.sweep(now: t0.addingTimeInterval(2)), ["com.hnc.Discord"], "nil was not cached")
        _ = enforcer.sweep(now: t0.addingTimeInterval(3))
        XCTAssertEqual(lookups, 2, "…but a successful lookup is")
    }

    func testPolicyProtectedAppsAreNeverSignalledEvenIfListed() {
        // A hand-edited list naming Finder/loginwindow must not make root kill the session.
        let procs = FakeProcesses()
        let sigs = FakeSignals()
        let enforcer = AppBlockEnforcer(processes: procs, signals: sigs,
                                        bundleIdentifier: { _ in "com.apple.Finder" },
                                        forceKillAfter: 3, protectedBundleIDs: [], ownPID: 1)
        procs.processes = [RunningProcess(pid: 77, executablePath: "/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder")]
        enforcer.setBlockedBundleIDs(["com.apple.finder"], now: t0)
        _ = enforcer.sweep(now: t0.addingTimeInterval(1))
        XCTAssertTrue(sigs.terminated.isEmpty)
        XCTAssertTrue(sigs.killed.isEmpty)
    }

    func testClearingSetStopsEnforcement() {
        let (enforcer, procs, sigs) = make()
        procs.processes = [discordMain]
        enforcer.setBlockedBundleIDs(["com.hnc.Discord"], now: t0)
        XCTAssertEqual(sigs.terminated, [100])
        enforcer.setBlockedBundleIDs([], now: t0.addingTimeInterval(1))
        _ = enforcer.sweep(now: t0.addingTimeInterval(5))
        XCTAssertEqual(sigs.terminated, [100])
        XCTAssertTrue(sigs.killed.isEmpty)
        XCTAssertEqual(enforcer.blockedBundleIDs, [])
    }

    func testBundleLookupIsCachedPerRoot() {
        var lookups: [String] = []
        let procs = FakeProcesses()
        let sigs = FakeSignals()
        let enforcer = AppBlockEnforcer(processes: procs, signals: sigs,
                                        bundleIdentifier: { root in lookups.append(root); return "com.hnc.Discord" },
                                        forceKillAfter: 3, protectedBundleIDs: [], ownPID: 1)
        enforcer.setBlockedBundleIDs(["com.hnc.Discord"], now: t0)
        procs.processes = [discordMain, discordHelper]
        _ = enforcer.sweep(now: t0.addingTimeInterval(1))
        _ = enforcer.sweep(now: t0.addingTimeInterval(2))
        XCTAssertEqual(lookups, ["/Applications/Discord.app"], "one plist read per bundle root, ever")
    }

    // MARK: store

    func testBlockedAppsStoreRoundTripAndMissingDefault() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-\(UUID().uuidString)/blockedapps.json")
        let store = BlockedAppsStore(url: url)
        XCTAssertEqual(try store.load(), [])
        try store.save(["com.hnc.Discord", "com.valvesoftware.steam"])
        XCTAssertEqual(try store.load(), ["com.hnc.Discord", "com.valvesoftware.steam"])
    }
}
