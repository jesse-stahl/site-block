import Foundation
import Network

/// A loopback listener for port 443 that never completes a TLS handshake — it exists solely to
/// observe WHICH blocked domain a browser tried to reach over https.
///
/// Browsers auto-upgrade many blocked domains to https (HSTS preload), so their attempts arrive
/// here rather than at the port-80 blocked-page server. We read the first bytes of the connection,
/// extract the SNI server name from the ClientHello, report it, and close. The browser still shows
/// its own connection error (we hold no certificate for the domain — by design), but the attempt
/// gets counted.
public final class TLSBlockSensor {

    /// Called with the SNI host (lowercased) of each observed ClientHello. Invoked on the
    /// sensor's queue.
    public var onClientHello: ((String) -> Void)?

    private let queue = DispatchQueue(label: "today.siteblock.tlssensor")
    private var listener: NWListener?

    /// The port the listener is bound to once started (nil before `start`).
    public private(set) var port: UInt16?

    public init() {}

    /// Start listening. Blocks until the listener is ready (or throws on failure/timeout).
    /// - Parameter port: the TCP port to bind; pass `0` (default) for an OS-assigned ephemeral
    ///   port, which the tests use. Production uses `443`.
    public func start(port requestedPort: UInt16 = 0) throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        // Loopback only — exactly like the blocked-page server, this must never serve the LAN.
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

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        // A ClientHello arrives in the first TCP segment in practice; if it doesn't parse we just
        // close (the site is blocked either way — only the count would be missed).
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            if let data, let host = TLSClientHello.sni(in: data) {
                self?.onClientHello?(host)
            }
            connection.cancel()
        }
    }
}
