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

    override init() {
        super.init()
        // Serve the blocked page on port 80 so redirected http requests get a real response.
        // Failure here is non-fatal: blocking still works, sites just fail to load instead of
        // showing the custom page.
        try? blockedPage.start(port: 80)
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
