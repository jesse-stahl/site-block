import XCTest
import Network
@testable import SiteBlockCore

final class TLSBlockSensorTests: XCTestCase {

    func testReportsSNIHostFromRealConnection() throws {
        let sensor = TLSBlockSensor()
        try sensor.start() // ephemeral port
        defer { sensor.stop() }
        let port = try XCTUnwrap(sensor.port)

        let reported = expectation(description: "SNI host reported")
        sensor.onClientHello = { host in
            XCTAssertEqual(host, "facebook.com")
            reported.fulfill()
        }

        send(makeClientHello(host: "facebook.com"), toPort: port)
        wait(for: [reported], timeout: 5)
    }

    func testGarbageBytesReportNothingAndDoNotCrash() throws {
        let sensor = TLSBlockSensor()
        try sensor.start()
        defer { sensor.stop() }
        let port = try XCTUnwrap(sensor.port)

        sensor.onClientHello = { _ in
            XCTFail("garbage must not produce an SNI report")
        }

        send(Data("GET / HTTP/1.1\r\nHost: x\r\n\r\n".utf8), toPort: port)
        // Give the sensor a moment to (not) fire — then we're done. The real assertion is the
        // XCTFail above never triggering plus no crash.
        let settle = expectation(description: "settle")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { settle.fulfill() }
        wait(for: [settle], timeout: 2)
    }

    func testStopReleasesPort() throws {
        let sensor = TLSBlockSensor()
        try sensor.start()
        XCTAssertNotNil(sensor.port)
        sensor.stop()
        XCTAssertNil(sensor.port)
    }

    func testSilentConnectionIsClosedByIdleTimeout() throws {
        // A peer that connects but never sends must not hold a helper fd forever.
        let sensor = TLSBlockSensor(idleTimeout: 0.3)
        try sensor.start()
        defer { sensor.stop() }
        let port = try XCTUnwrap(sensor.port)

        let closed = expectation(description: "server closed the idle connection")
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        // Observe EOF/reset from the server closing on us. The receive completion fires exactly
        // once, making it the single safe fulfill site (a state handler would double-fulfill).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, isComplete, error in
            if isComplete || error != nil { closed.fulfill() }
        }
        connection.start(queue: .global())
        defer { connection.cancel() }

        wait(for: [closed], timeout: 5)
    }

    // MARK: helper

    /// Open a raw TCP connection to the loopback sensor and write `data`.
    private func send(_ data: Data, toPort port: UInt16) {
        let connection = NWConnection(
            host: .ipv4(.loopback),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp
        )
        connection.start(queue: .global())
        connection.send(content: data, completion: .contentProcessed { _ in })
        // The sensor closes the connection itself; keep ours alive long enough to deliver.
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { connection.cancel() }
    }
}
