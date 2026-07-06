import Foundation
import SiteBlockCore

/// The privileged helper daemon. Registered once via `SMAppService`, it runs as root and performs
/// the `/etc/hosts` edits on behalf of the app over XPC. It also serves the blocked page on the
/// loopback so `http://` requests to blocked domains get the friendly page.
///
/// This is deliberately thin — every hosts transformation is done by the well-tested
/// `SiteBlockCore.HostsFile`, keeping the privileged code minimal and auditable.
final class HostsControlService: NSObject, HostsControlProtocol {

    private let writer = HostsFileWriter.system
    private let blockedPage = BlockedPageServer()
    private let tlsSensor = TLSBlockSensor()
    private let recorder = BlockEventRecorder()
    /// Root-owned stats file — the helper is the only writer; the app reads via XPC.
    private let statsStore = BlockStatsStore(
        url: URL(fileURLWithPath: "/Library/Application Support/SiteBlock/blockstats.json"))

    override init() {
        super.init()
        // Tallies survive helper restarts/reboots.
        if let saved = try? statsStore.load() { recorder.restore(saved) }

        // Serve the blocked page on port 80 so redirected http requests get a real response, and
        // watch port 443 for the (far more common) HSTS-upgraded https attempts — we can't serve
        // a page there without the domain's certificate, but the SNI tells us what was blocked.
        // Failures are non-fatal: blocking still works, attempts just go uncounted.
        try? blockedPage.start(port: 80)
        try? tlsSensor.start(port: 443)
        blockedPage.onHit = { [weak self] host in self?.recordAttempt(host) }
        tlsSensor.onClientHello = { [weak self] host in self?.recordAttempt(host) }
    }

    /// Count an observed access attempt — but only for hosts we are actually blocking right now,
    /// so stray loopback traffic (local dev servers, etc.) never lands in the tallies. Note the
    /// guarantee's limit: loopback carries no peer identity, so a local process CAN craft hits
    /// for a currently-blocked domain. Counts are motivational display, never a security input.
    private func recordAttempt(_ host: String) {
        guard let managed = try? writer.currentManagedHosts(), managed.contains(host) else { return }
        // Persist only when a new event was counted (coalescing absorbs the connection storms
        // browsers fire per visit, keeping disk writes rare).
        if recorder.recordHit(host: host) {
            try? statsStore.save(recorder.stats)
        }
    }

    func apply(hosts: [String], withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try writer.apply(hosts)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func removeBlock(withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try writer.removeRegion()
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func currentManagedHosts(withReply reply: @escaping ([String]) -> Void) {
        reply((try? writer.currentManagedHosts()) ?? [])
    }

    func blockStats(withReply reply: @escaping (Data?) -> Void) {
        reply(try? JSONEncoder().encode(recorder.stats))
    }
}

/// Accepts incoming XPC connections from the app and wires them to the service.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HostsControlService()

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        newConnection.exportedInterface = NSXPCInterface(with: HostsControlProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperInfo.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
