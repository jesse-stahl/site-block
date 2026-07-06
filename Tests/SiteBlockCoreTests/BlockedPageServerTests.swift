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
