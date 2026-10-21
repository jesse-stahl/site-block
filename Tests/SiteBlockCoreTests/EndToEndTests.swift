import XCTest
@testable import SiteBlockCore

/// End-to-end verification: drive `AppModel` against a REAL hosts file on disk (via
/// `HostsFileWriter`, the same code the privileged helper uses) through the full asymmetric
/// friction timeline. This exercises the actual stack — model → hosts rendering → atomic file
/// write — not mocks, proving blocking is applied/removed correctly and content outside the
/// managed region is never touched.
private final class DiskHosts: HostsApplying, @unchecked Sendable {
    let writer: HostsFileWriter
    init(path: URL) { writer = HostsFileWriter(path: path) }
    func apply(_ hosts: [String]) async throws { try writer.apply(hosts) }
    func removeBlock() async throws { try writer.removeRegion() }
    func currentManagedHosts() async throws -> [String] { try writer.currentManagedHosts() }
}

private final class OKAuth: PasswordAuthenticating, @unchecked Sendable {
    func authenticate(reason: String) async -> Bool { true }
}

@MainActor
final class EndToEndTests: XCTestCase {

    func testFullBlockThenGatedUnblockAgainstRealHostsFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("siteblock-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let hostsPath = dir.appendingPathComponent("hosts")
        let preamble = "127.0.0.1\tlocalhost\n255.255.255.255\tbroadcasthost\n"
        try Data(preamble.utf8).write(to: hostsPath)

        let t0 = Date(timeIntervalSinceReferenceDate: 3_000_000)
        var clockNow = t0
        let model = AppModel(
            store: BlockListStore(url: dir.appendingPathComponent("blocklist.json")),
            hosts: DiskHosts(path: hostsPath),
            auth: OKAuth(),
            clock: { clockNow }
        )

        // 1. Strengthen: turn on + add a domain (instant). The real hosts file gets the region.
        await model.turnBlockingOn()
        await model.addDomain("facebook.com")

        var onDisk = try String(contentsOf: hostsPath, encoding: .utf8)
        XCTAssertTrue(onDisk.contains("127.0.0.1 facebook.com"), "base domain blocked on disk")
        XCTAssertTrue(onDisk.contains("127.0.0.1 www.facebook.com"), "www auto-covered")
        XCTAssertTrue(onDisk.contains("127.0.0.1 m.facebook.com"), "common subdomain auto-covered")
        XCTAssertTrue(onDisk.contains("::1 facebook.com"), "IPv6 mapped")
        XCTAssertTrue(onDisk.contains("127.0.0.1\tlocalhost"), "preamble untouched")

        // 2. Weaken is gated: request turn-off, cannot confirm during the 5-min cooldown.
        model.requestTurnOff()
        clockNow = t0.addingTimeInterval(299)
        model.tick()
        let early = await model.confirmPending()
        XCTAssertFalse(early, "cannot unblock during cooldown")
        XCTAssertTrue(try String(contentsOf: hostsPath, encoding: .utf8).contains("facebook.com"),
                      "still blocked on disk during cooldown")

        // 3. After the cooldown, within the 2-min window, confirm succeeds → region removed.
        clockNow = t0.addingTimeInterval(330)
        model.tick()
        XCTAssertTrue(model.canConfirm)
        let ok = await model.confirmPending()
        XCTAssertTrue(ok, "confirm succeeds within the window")

        onDisk = try String(contentsOf: hostsPath, encoding: .utf8)
        XCTAssertFalse(onDisk.contains(HostsFile.beginMarker), "managed region removed")
        XCTAssertFalse(onDisk.contains("facebook.com"), "no blocked hosts remain")
        XCTAssertTrue(onDisk.contains("127.0.0.1\tlocalhost"), "preamble preserved through the whole cycle")
        XCTAssertTrue(onDisk.contains("broadcasthost"))
    }
}
