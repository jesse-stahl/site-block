import XCTest
@testable import SiteBlockCore

final class HostsFileTests: XCTestCase {

    let preamble = """
    ##
    # Host Database
    ##
    127.0.0.1\tlocalhost
    255.255.255.255\tbroadcasthost
    ::1\tlocalhost
    """

    // MARK: renderRegion

    func testRenderRegionHasMarkersAndBothFamilies() {
        let region = HostsFile.renderRegion(["facebook.com", "x.com"])
        XCTAssertTrue(region.hasPrefix(HostsFile.beginMarker))
        XCTAssertTrue(region.hasSuffix(HostsFile.endMarker))
        XCTAssertTrue(region.contains("127.0.0.1 facebook.com"))
        XCTAssertTrue(region.contains("::1 facebook.com"))
        XCTAssertTrue(region.contains("127.0.0.1 x.com"))
        XCTAssertTrue(region.contains("::1 x.com"))
    }

    // MARK: applying

    func testApplyingAppendsRegionAndPreservesPreamble() {
        let result = HostsFile.applying(["facebook.com"], to: preamble)
        XCTAssertTrue(result.contains(preamble), "original content preserved")
        XCTAssertTrue(result.contains(HostsFile.beginMarker))
        XCTAssertTrue(result.contains("127.0.0.1 facebook.com"))
        XCTAssertTrue(result.hasSuffix("\n"))
    }

    func testApplyingReplacesExistingRegionInPlace() {
        let once = HostsFile.applying(["facebook.com"], to: preamble)
        let twice = HostsFile.applying(["twitter.com"], to: once)
        // Exactly one region.
        XCTAssertEqual(twice.components(separatedBy: HostsFile.beginMarker).count - 1, 1)
        XCTAssertTrue(twice.contains("127.0.0.1 twitter.com"))
        XCTAssertFalse(twice.contains("127.0.0.1 facebook.com"))
        XCTAssertTrue(twice.contains(preamble))
    }

    func testApplyingIsIdempotent() {
        let once = HostsFile.applying(["facebook.com", "x.com"], to: preamble)
        let twice = HostsFile.applying(["facebook.com", "x.com"], to: once)
        XCTAssertEqual(once, twice)
    }

    func testApplyingEmptyRemovesRegion() {
        let withRegion = HostsFile.applying(["facebook.com"], to: preamble)
        let cleared = HostsFile.applying([], to: withRegion)
        XCTAssertFalse(cleared.contains(HostsFile.beginMarker))
        XCTAssertTrue(cleared.contains("127.0.0.1\tlocalhost"))
    }

    func testApplyingToEmptyContent() {
        let result = HostsFile.applying(["facebook.com"], to: "")
        XCTAssertTrue(result.contains(HostsFile.beginMarker))
        XCTAssertTrue(result.contains("127.0.0.1 facebook.com"))
    }

    // MARK: removing

    func testRemovingStripsRegionButKeepsEverythingElse() {
        let withRegion = HostsFile.applying(["facebook.com"], to: preamble)
        let removed = HostsFile.removing(from: withRegion)
        XCTAssertFalse(removed.contains(HostsFile.beginMarker))
        XCTAssertFalse(removed.contains(HostsFile.endMarker))
        XCTAssertFalse(removed.contains("127.0.0.1 facebook.com"))
        XCTAssertTrue(removed.contains("127.0.0.1\tlocalhost"))
        XCTAssertTrue(removed.contains("broadcasthost"))
    }

    func testRemovingNoRegionIsNoOp() {
        XCTAssertEqual(HostsFile.removing(from: preamble), preamble)
    }

    // MARK: managedHosts

    func testManagedHostsParsesRegion() {
        let withRegion = HostsFile.applying(["facebook.com", "x.com"], to: preamble)
        XCTAssertEqual(HostsFile.managedHosts(in: withRegion), ["facebook.com", "x.com"])
    }

    func testManagedHostsEmptyWhenNoRegion() {
        XCTAssertEqual(HostsFile.managedHosts(in: preamble), [])
    }

    func testRemovingStripsAllRegionsIncludingDuplicates() {
        // A malformed file with two managed regions (e.g. from manual tampering) must be fully
        // cleaned — no orphaned region left behind.
        let doubled = HostsFile.applying(["a.com"], to: preamble) + "\n"
            + HostsFile.renderRegion(["b.com"]) + "\n"
        XCTAssertEqual(doubled.components(separatedBy: HostsFile.beginMarker).count - 1, 2)
        let cleaned = HostsFile.removing(from: doubled)
        XCTAssertFalse(cleaned.contains(HostsFile.beginMarker))
        XCTAssertFalse(cleaned.contains("a.com"))
        XCTAssertFalse(cleaned.contains("b.com"))
        XCTAssertTrue(cleaned.contains("broadcasthost"), "non-managed content preserved")
    }

    func testApplyingCollapsesDuplicateRegionsToOne() {
        let doubled = HostsFile.applying(["a.com"], to: preamble) + "\n"
            + HostsFile.renderRegion(["b.com"]) + "\n"
        let result = HostsFile.applying(["c.com"], to: doubled)
        XCTAssertEqual(result.components(separatedBy: HostsFile.beginMarker).count - 1, 1,
                       "exactly one managed region after apply")
        XCTAssertTrue(result.contains("127.0.0.1 c.com"))
        XCTAssertFalse(result.contains("a.com"))
        XCTAssertFalse(result.contains("b.com"))
    }

    // MARK: HostsFileWriter (atomic file I/O)

    func testWriterApplyReadRemoveRoundTrip() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-hosts-\(UUID().uuidString)")
        try Data(preamble.utf8).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let writer = HostsFileWriter(path: tmp)
        try writer.apply(["facebook.com", "x.com"])
        XCTAssertEqual(try writer.currentManagedHosts(), ["facebook.com", "x.com"])

        let onDisk = try String(contentsOf: tmp, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("127.0.0.1\tlocalhost"), "preamble preserved on disk")
        XCTAssertTrue(onDisk.contains("127.0.0.1 facebook.com"))

        try writer.removeRegion()
        XCTAssertEqual(try writer.currentManagedHosts(), [])
        XCTAssertTrue(try String(contentsOf: tmp, encoding: .utf8).contains("broadcasthost"))
    }

    func testWriterReadsMissingFileAsEmpty() throws {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-missing-\(UUID().uuidString)")
        let writer = HostsFileWriter(path: missing)
        XCTAssertEqual(try writer.read(), "")
        XCTAssertEqual(try writer.currentManagedHosts(), [])
    }
}
