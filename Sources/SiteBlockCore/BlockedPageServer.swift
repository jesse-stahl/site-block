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

    /// Called with the request's `Host` header value (lowercased, port stripped) whenever a
    /// redirected request is served — this is how block attempts get counted. Invoked on the
    /// server's queue.
    public var onHit: ((String) -> Void)?

    /// The port the listener is bound to once started (nil before `start`).
    public private(set) var port: UInt16?

    /// How long an accepted connection may sit without delivering bytes before being closed.
    /// Without this, a peer that connects and sends nothing would hold a root-helper file
    /// descriptor forever (the receive completion never fires for a silent socket).
    private let idleTimeout: TimeInterval

    /// - Parameter html: the page body to serve. Defaults to the bundled `blocked.html`.
    public init(html: String = SiteBlockResources.blockedPageHTML, idleTimeout: TimeInterval = 10) {
        self.html = html
        self.idleTimeout = idleTimeout
    }

    /// Start listening. Blocks until the listener is ready (or throws on failure/timeout).
    /// - Parameter port: the TCP port to bind; pass `0` (default) for an OS-assigned ephemeral
    ///   port, which the tests use. Production uses `80`.
    public func start(port requestedPort: UInt16 = 0) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Bind loopback only. Blocked domains resolve to 127.0.0.1, so only local redirected
        // traffic should ever reach this server — never the LAN (the helper runs as root on :80).
        params.requiredInterfaceType = .loopback
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
        // Read the request — any request gets the blocked page, but the Host header tells us
        // WHICH blocked site was attempted, which feeds the block counter.
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, _, _ in
            if let data, let host = Self.hostHeader(in: data) {
                self?.onHit?(host)
            }
            self?.respond(on: connection)
        }
        // Idle deadline: a peer that never sends leaves the receive completion unfired, so
        // enforce an upper bound on the connection's lifetime. cancel() after completion is a
        // safe no-op; the weak capture lets an already-closed connection deallocate.
        queue.asyncAfter(deadline: .now() + idleTimeout) { [weak connection] in
            connection?.cancel()
        }
    }

    /// Extract the `Host` header value from a raw HTTP request: lowercased, `:port` stripped.
    /// Nil if the bytes aren't parseable as headers or carry no Host.
    static func hostHeader(in data: Data) -> String? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        for line in text.components(separatedBy: "\r\n").dropFirst() {
            if line.isEmpty { break } // end of headers
            let parts = line.split(separator: ":", maxSplits: 1)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "host"
            else { continue }
            var host = parts[1].trimmingCharacters(in: .whitespaces).lowercased()
            if let portIndex = host.lastIndex(of: ":"), host[host.index(after: portIndex)...].allSatisfy(\.isNumber) {
                host = String(host[..<portIndex])
            }
            return host.isEmpty ? nil : host
        }
        return nil
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
