import XCTest
@testable import SiteBlockCore

final class FrictionMachineTests: XCTestCase {

    let t0 = Date(timeIntervalSinceReferenceDate: 1_000_000)

    private func machine() -> FrictionMachine {
        FrictionMachine(cooldown: 300, window: 120)
    }

    func testStartsIdle() {
        XCTAssertEqual(machine().state, .idle)
    }

    func testRequestStartsCooldown() {
        var m = machine()
        m.request(now: t0)
        XCTAssertEqual(m.state, .cooling(deadline: t0.addingTimeInterval(300)))
        XCTAssertEqual(m.remainingCooldown(now: t0), 300)
    }

    func testRepeatedRequestDoesNotResetTimer() {
        var m = machine()
        m.request(now: t0)
        m.request(now: t0.addingTimeInterval(60)) // second click 1 min later
        // Deadline still anchored to the first request.
        XCTAssertEqual(m.state, .cooling(deadline: t0.addingTimeInterval(300)))
        XCTAssertEqual(m.remainingCooldown(now: t0.addingTimeInterval(60)), 240)
    }

    func testCannotConfirmDuringCooldown() {
        var m = machine()
        m.request(now: t0)
        XCTAssertFalse(m.confirm(now: t0.addingTimeInterval(299)))
        // Still cooling, not knocked out of the flow.
        if case .cooling = m.state {} else { XCTFail("expected still cooling, got \(m.state)") }
    }

    func testWindowOpensAfterCooldown() {
        var m = machine()
        m.request(now: t0)
        m.tick(now: t0.addingTimeInterval(300))
        XCTAssertEqual(m.state, .armed(windowEnds: t0.addingTimeInterval(420)))
        XCTAssertEqual(m.remainingWindow(now: t0.addingTimeInterval(300)), 120)
        XCTAssertTrue(m.canConfirm(now: t0.addingTimeInterval(300)))
    }

    func testConfirmSucceedsWithinWindow() {
        var m = machine()
        m.request(now: t0)
        XCTAssertTrue(m.confirm(now: t0.addingTimeInterval(360))) // 1 min into the window
        XCTAssertEqual(m.state, .confirmed)
    }

    func testConfirmAtExactDeadlineSucceeds() {
        var m = machine()
        m.request(now: t0)
        XCTAssertTrue(m.confirm(now: t0.addingTimeInterval(300)))
    }

    func testWindowExpiresBackToIdle() {
        var m = machine()
        m.request(now: t0)
        m.tick(now: t0.addingTimeInterval(421)) // 1s past the 300+120 window
        XCTAssertEqual(m.state, .idle)
    }

    func testConfirmAfterWindowFailsAndResets() {
        var m = machine()
        m.request(now: t0)
        XCTAssertFalse(m.confirm(now: t0.addingTimeInterval(500)))
        XCTAssertEqual(m.state, .idle)
    }

    func testResetReturnsToIdle() {
        var m = machine()
        m.request(now: t0)
        m.tick(now: t0.addingTimeInterval(310)) // armed
        m.reset()
        XCTAssertEqual(m.state, .idle)
        XCTAssertNil(m.remainingCooldown(now: t0))
        XCTAssertNil(m.remainingWindow(now: t0))
    }

    func testRemainingHelpersNilWhenIdle() {
        let m = machine()
        XCTAssertNil(m.remainingCooldown(now: t0))
        XCTAssertNil(m.remainingWindow(now: t0))
        XCTAssertFalse(m.canConfirm(now: t0))
    }

    func testFullHappyPath() {
        var m = machine()
        XCTAssertEqual(m.state, .idle)
        m.request(now: t0)
        m.tick(now: t0.addingTimeInterval(150)) // mid-cooldown
        XCTAssertEqual(m.remainingCooldown(now: t0.addingTimeInterval(150)), 150)
        XCTAssertFalse(m.canConfirm(now: t0.addingTimeInterval(150)))
        m.tick(now: t0.addingTimeInterval(300)) // window opens
        XCTAssertTrue(m.canConfirm(now: t0.addingTimeInterval(300)))
        XCTAssertTrue(m.confirm(now: t0.addingTimeInterval(330)))
        XCTAssertEqual(m.state, .confirmed)
    }
}
