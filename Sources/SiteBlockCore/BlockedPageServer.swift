import Foundation
import Network

/// A minimal loopback HTTP server that answers every request with the custom "blocked" page.
///
/// Blocked domains are redirected to `127.0.0.1` in the hosts file; this server, run on port 80
/// by the privileged helper, is what serves the friendly page for `http://` requests. (`https`
/// requests never reach it — the browser shows its own security warning first.) It responds to
/// any path/method with `200 OK` and the page body, then closes the connection.
public final class BlockedPageServer {

    private let html: String
    private let queue = DispatchQueue(label: "today.siteblock.blockedpage")
    private var listener: NWListener?

    /// The port the listener is bound to once started (nil before `start`).
    public private(set) var port: UInt16?

    /// - Parameter html: the page body to serve. Defaults to the bundled `blocked.html`.
    public init(html: String = SiteBlockResources.blockedPageHTML) {
        self.html = html
    }

    /// Start listening. Blocks until the listener is ready (or throws on failure/timeout).
    /// - Parameter port: the TCP port to bind; pass `0` (default) for an OS-assigned ephemeral
    ///   port, which the tests use. Production uses `80`.
    public func start(port requestedPort: UInt16 = 0) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let nwPort = NWEndpoint.Port(rawValue: requestedPort) ?? .any
        let listener = try NWListener(using: params, on: nwPort)
        self.listener = listener

        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        let ready = DispatchSemaphore(value: 0)
        var startError: Error?
        listener.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.port = listener.port?.rawValue
                ready.signal()
            case .failed(let error):
                startError = error
                ready.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        if ready.wait(timeout: .now() + 5) == .timedOut {
            listener.cancel()
            throw BlockedPageServerError.startTimedOut
        }
        if let startError {
            listener.cancel()
            throw startError
        }
    }

    /// Stop listening and release the port.
    public func stop() {
        listener?.cancel()
        listener = nil
        port = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // Read the request (we don't parse it — any request gets the blocked page), then reply.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] _, _, _, _ in
            self?.respond(on: connection)
        }
    }

    private func respond(on connection: NWConnection) {
        let body = Data(html.utf8)
        let headerLines = [
            "HTTP/1.1 200 OK",
            "Content-Type: text/html; charset=utf-8",
            "Content-Length: \(body.count)",
            "Cache-Control: no-store",
            "Connection: close",
        ]
        // CRLF between headers, and a blank CRLF line separating headers from the body.
        let header = headerLines.joined(separator: "\r\n") + "\r\n\r\n"
        var response = Data(header.utf8)
        response.append(body)
        connection.send(content: response, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}

public enum BlockedPageServerError: Error {
    case startTimedOut
}
