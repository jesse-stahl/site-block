import XCTest
@testable import SiteBlockCore

/// A controllable clock for deterministic time in tests.
private final class TestClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

final class BlockStatsTests: XCTestCase {

    let t0 = Date(timeIntervalSinceReferenceDate: 2_000_000)

    private func makeRecorder(coalescing: TimeInterval = 5) -> (BlockEventRecorder, TestClock) {
        let clock = TestClock(t0)
        let recorder = BlockEventRecorder(coalescing: coalescing, clock: { clock.now })
        return (recorder, clock)
    }

    // MARK: coalescing

    func testFirstHitCounts() {
        let (recorder, _) = makeRecorder()
        XCTAssertTrue(recorder.recordHit(host: "facebook.com"))
        XCTAssertEqual(recorder.stats.counts["facebook.com"], 1)
    }

    func testSecondHitWithinWindowIsCoalesced() {
        let (recorder, clock) = makeRecorder()
        XCTAssertTrue(recorder.recordHit(host: "facebook.com"))
        clock.advance(1)
        XCTAssertFalse(recorder.recordHit(host: "facebook.com"))
        XCTAssertEqual(recorder.stats.counts["facebook.com"], 1)
    }

    func testHitAfterWindowElapsedCounts() {
        let (recorder, clock) = makeRecorder()
        XCTAssertTrue(recorder.recordHit(host: "facebook.com"))
        clock.advance(6)
        XCTAssertTrue(recorder.recordHit(host: "facebook.com"))
        XCTAssertEqual(recorder.stats.counts["facebook.com"], 2)
    }

    func testDifferentHostsDoNotCoalesce() {
        let (recorder, _) = makeRecorder()
        XCTAssertTrue(recorder.recordHit(host: "facebook.com"))
        XCTAssertTrue(recorder.recordHit(host: "x.com"))
        XCTAssertEqual(recorder.stats.counts["facebook.com"], 1)
        XCTAssertEqual(recorder.stats.counts["x.com"], 1)
    }

    // MARK: normalization

    func testNormalizationTrailingDotMatchesLowercase() {
        let (recorder, _) = makeRecorder()
        XCTAssertTrue(recorder.recordHit(host: "Facebook.com."))
        XCTAssertFalse(recorder.recordHit(host: "facebook.com"), "same host after normalization coalesces")
        XCTAssertEqual(recorder.stats.counts["facebook.com"], 1)
    }

    func testNormalizationStripsPort() {
        let (recorder, _) = makeRecorder()
        XCTAssertTrue(recorder.recordHit(host: "facebook.com:80"))
        XCTAssertFalse(recorder.recordHit(host: "facebook.com"), "port-stripped host coalesces")
        XCTAssertEqual(recorder.stats.counts["facebook.com"], 1)
        XCTAssertNil(recorder.stats.counts["facebook.com:80"])
    }

    func testEmptyHostIsIgnored() {
        let (recorder, _) = makeRecorder()
        XCTAssertFalse(recorder.recordHit(host: ""))
        XCTAssertEqual(recorder.stats.total, 0)
        XCTAssertTrue(recorder.stats.counts.isEmpty)
    }

    // MARK: total

    func testTotalSumsAcrossHosts() {
        let (recorder, _) = makeRecorder()
        recorder.recordHit(host: "facebook.com")
        recorder.recordHit(host: "x.com")
        recorder.recordHit(host: "y.com")
        XCTAssertEqual(recorder.stats.total, 3)
    }

    // MARK: restore

    func testRestoreReplacesCountsAndSubsequentHitsAddOnTop() {
        let (recorder, clock) = makeRecorder()
        recorder.recordHit(host: "facebook.com")
        recorder.restore(BlockStats(counts: ["facebook.com": 10, "x.com": 5]))
        XCTAssertEqual(recorder.stats.counts["facebook.com"], 10)
        XCTAssertEqual(recorder.stats.counts["x.com"], 5)

        // Coalescing state is transient, not tied to restored counts, so a hit right after
        // restore (for a host that was hit before restore) still counts since restore doesn't
        // reset lastCounted for a NEW host, but for facebook.com the prior hit's timestamp still
        // applies. Advance the clock to be unambiguous either way.
        clock.advance(10)
        XCTAssertTrue(recorder.recordHit(host: "facebook.com"))
        XCTAssertEqual(recorder.stats.counts["facebook.com"], 11)
        XCTAssertTrue(recorder.recordHit(host: "x.com"))
        XCTAssertEqual(recorder.stats.counts["x.com"], 6)
    }

    // MARK: persistence

    func testStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlockStatsStore(url: dir.appendingPathComponent("stats.json"))

        let stats = BlockStats(counts: ["facebook.com": 3, "x.com": 1])
        try store.save(stats)
        XCTAssertEqual(try store.load(), stats)
    }

    func testStoreLoadMissingReturnsEmptyStats() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-\(UUID().uuidString)/stats.json")
        let store = BlockStatsStore(url: url)
        XCTAssertEqual(try store.load(), BlockStats())
    }

    // MARK: concurrency

    func testConcurrentRecordHitIsThreadSafe() {
        let (recorder, _) = makeRecorder()
        let iterations = 100
        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            // Distinct host per iteration so coalescing never hides a race.
            recorder.recordHit(host: "host\(i).com")
        }
        XCTAssertEqual(recorder.stats.total, iterations)
    }
}
