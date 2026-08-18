import XCTest
@testable import SiteBlockCore

final class BlockedPageServerTests: XCTestCase {

    func testServesBlockedPageWith200ForAnyPath() throws {
        let marker = "BLOCKED-PAGE-TEST-BODY"
        let server = BlockedPageServer(html: "<html><body>\(marker)</body></html>")
        try server.start() // ephemeral port
        defer { server.stop() }

        let port = try XCTUnwrap(server.port)
        XCTAssertGreaterThan(port, 0)

        for path in ["/", "/anything", "/deep/path?with=query"] {
            let url = URL(string: "http://127.0.0.1:\(port)\(path)")!
            let (status, body) = try fetch(url)
            XCTAssertEqual(status, 200, "path \(path)")
            XCTAssertTrue(body.contains(marker), "blocked page body served for \(path)")
        }
    }

    func testStopReleasesPortAndClearsState() throws {
        let server = BlockedPageServer(html: "<html>x</html>")
        try server.start()
        XCTAssertNotNil(server.port)
        server.stop()
        XCTAssertNil(server.port)
    }

    func testUsesBundledPageByDefault() throws {
        // The default initializer pulls the bundled blocked.html; ensure it is non-empty HTML.
        let server = BlockedPageServer()
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)
        let (status, body) = try fetch(URL(string: "http://127.0.0.1:\(port)/")!)
        XCTAssertEqual(status, 200)
        XCTAssertTrue(body.lowercased().contains("<"), "served some HTML")
    }

    // MARK: hit reporting

    func testReportsHostHeaderOnHit() throws {
        let server = BlockedPageServer(html: "<html>x</html>")
        try server.start()
        defer { server.stop() }
        let port = try XCTUnwrap(server.port)

        let hit = expectation(description: "onHit fired")
        server.onHit = { host in
            // URLSession sends "Host: 127.0.0.1:PORT"; the port must be stripped.
            XCTAssertEqual(host, "127.0.0.1")
            hit.fulfill()
        }
        _ = try fetch(URL(string: "http://127.0.0.1:\(port)/")!)
        wait(for: [hit], timeout: 5)
    }

    func testHostHeaderParsing() {
        func req(_ hostLine: String) -> Data {
            Data("GET / HTTP/1.1\r\n\(hostLine)\r\nAccept: */*\r\n\r\n".utf8)
        }
        XCTAssertEqual(BlockedPageServer.hostHeader(in: req("Host: facebook.com")), "facebook.com")
        XCTAssertEqual(BlockedPageServer.hostHeader(in: req("host: FACEBOOK.com")), "facebook.com", "case-insensitive, lowercased")
        XCTAssertEqual(BlockedPageServer.hostHeader(in: req("Host: facebook.com:80")), "facebook.com", "port stripped")
        XCTAssertNil(BlockedPageServer.hostHeader(in: req("X-Other: nope")), "no Host header")
        XCTAssertNil(BlockedPageServer.hostHeader(in: Data([0xFF, 0xFE, 0x00])), "not UTF-8")
    }

    // MARK: helper

    private func fetch(_ url: URL) throws -> (Int, String) {
        let sem = DispatchSemaphore(value: 0)
        var statusCode = -1
        var bodyString = ""
        var fetchError: Error?

        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            if let error { fetchError = error }
            if let http = response as? HTTPURLResponse { statusCode = http.statusCode }
            if let data { bodyString = String(decoding: data, as: UTF8.self) }
            sem.signal()
        }
        task.resume()
        if sem.wait(timeout: .now() + 8) == .timedOut {
            throw BlockedPageServerError.startTimedOut
        }
        if let fetchError { throw fetchError }
        return (statusCode, bodyString)
    }
}
