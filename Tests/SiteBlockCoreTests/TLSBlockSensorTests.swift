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
