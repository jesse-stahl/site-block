import Foundation
import Security
import SiteBlockCore

/// The privileged helper daemon. Registered once via `SMAppService`, it runs as root and performs
/// the `/etc/hosts` edits on behalf of the app over XPC. It also serves the blocked page on the
/// loopback so `http://` requests to blocked domains get the friendly page.
///
/// This is deliberately thin — every hosts transformation is done by the well-tested
/// `SiteBlockCore.HostsFile`, keeping the privileged code minimal and auditable.
/// It also keeps blocked apps from running (see `ProcessWatcher`).
final class HostsControlService: NSObject, HostsControlProtocol {

    private let writer = HostsFileWriter.system
    private let blockedPage = BlockedPageServer()
    private let tlsSensor = TLSBlockSensor()
    private let recorder = BlockEventRecorder()
    /// Root-owned stats file — the helper is the only writer; the app reads via XPC.
    private let statsStore = BlockStatsStore(
        url: URL(fileURLWithPath: "/Library/Application Support/SiteBlock/blockstats.json"))
    /// Kills blocked apps; its set is persisted root-owned next to the stats file. Blocked-app
    /// launches count as attempts under their namespaced key, so the app can show per-app tallies
    /// and the "kept you focused" banner just like for sites. (`lazy` so the callback can capture
    /// self; the watcher is started from `init` once everything else is wired.)
    private lazy var processWatcher = ProcessWatcher(
        store: BlockedAppsStore(url: URL(fileURLWithPath: "/Library/Application Support/SiteBlock/blockedapps.json")),
        onAttempt: { [weak self] bundleID in
            guard let self else { return }
            if recorder.recordHit(host: BlockedApp.statsKey(for: bundleID)) {
                try? statsStore.save(recorder.stats)
            }
        })

    /// In-memory copy of the managed host set, so per-hit filtering never touches the disk —
    /// browsers fire many connection attempts per visit and hits arrive on the blocked-page and
    /// TLS-sensor queues while XPC mutations arrive concurrently, hence the lock.
    private let managedLock = NSLock()
    private var managedCache: Set<String> = []

    override init() {
        super.init()
        // Tallies survive helper restarts/reboots.
        if let saved = try? statsStore.load() { recorder.restore(saved) }
        managedCache = Set((try? writer.currentManagedHosts()) ?? [])

        // Serve the blocked page on port 80 so redirected http requests get a real response, and
        // watch port 443 for the (far more common) HSTS-upgraded https attempts — we can't serve
        // a page there without the domain's certificate, but the SNI tells us what was blocked.
        // Failures are non-fatal: blocking still works, attempts just go uncounted.
        try? blockedPage.start(port: 80)
        try? tlsSensor.start(port: 443)
        blockedPage.onHit = { [weak self] host in self?.recordAttempt(host) }
        tlsSensor.onClientHello = { [weak self] host in self?.recordAttempt(host) }

        // Restore and enforce the persisted app set (kills auto-launched blocked apps at login
        // even before the menu bar app has reconciled).
        processWatcher.start()
    }

    /// Count an observed access attempt — but only for hosts we are actually blocking right now,
    /// so stray loopback traffic (local dev servers, etc.) never lands in the tallies. Note the
    /// guarantee's limit: loopback carries no peer identity, so a local process CAN craft hits
    /// for a currently-blocked domain. Counts are motivational display, never a security input.
    private func recordAttempt(_ host: String) {
        managedLock.lock()
        let isManaged = managedCache.contains(host)
        managedLock.unlock()
        guard isManaged else { return }
        // Persist only when a new event was counted (coalescing absorbs the connection storms
        // browsers fire per visit, keeping disk writes rare).
        if recorder.recordHit(host: host) {
            try? statsStore.save(recorder.stats)
        }
    }

    /// Refresh the in-memory managed set after a successful hosts write.
    private func updateManagedCache(_ hosts: [String]) {
        managedLock.lock()
        managedCache = Set(hosts)
        managedLock.unlock()
    }

    func apply(hosts: [String], withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try writer.apply(hosts)
            updateManagedCache(hosts)
            reply(true, nil)
        } catch {
            reply(false, error.localizedDescription)
        }
    }

    func removeBlock(withReply reply: @escaping (Bool, String?) -> Void) {
        do {
            try writer.removeRegion()
            updateManagedCache([])
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

    /// Replies once the set is live. A persistence failure is reported as an error — the set is
    /// enforced now, but it would not survive a reboot, and the app must not report "verified".
    func applyBlockedApps(bundleIDs: [String], withReply reply: @escaping (Bool, String?) -> Void) {
        processWatcher.setBlockedApps(bundleIDs) { saveError in
            if let saveError {
                reply(false, "Couldn't save the blocked-app list: \(saveError.localizedDescription)")
            } else {
                reply(true, nil)
            }
        }
    }

    func currentBlockedApps(withReply reply: @escaping ([String]) -> Void) {
        reply(processWatcher.currentBlockedApps())
    }
}

/// Accepts incoming XPC connections from the app and wires them to the service.
final class HelperListenerDelegate: NSObject, NSXPCListenerDelegate {
    private let service = HostsControlService()

    /// Built once from the helper's own signature, so the app and helper only need to share a
    /// signing team — no team id is baked into the source.
    private let clientRequirement: String? = ownTeamIdentifier().flatMap(HelperInfo.clientRequirement(teamID:))

    func listener(_ listener: NSXPCListener,
                  shouldAcceptNewConnection newConnection: NSXPCConnection) -> Bool {
        // Unsigned helper (or unreadable signature) → accept nobody rather than everybody.
        guard let clientRequirement else { return false }
        // The system checks the caller's signature and invalidates the connection on mismatch,
        // before any message reaches the service.
        newConnection.setCodeSigningRequirement(clientRequirement)
        newConnection.exportedInterface = NSXPCInterface(with: HostsControlProtocol.self)
        newConnection.exportedObject = service
        newConnection.resume()
        return true
    }
}

/// The team identifier this helper binary is signed with, or nil if it is unsigned/ad-hoc.
private func ownTeamIdentifier() -> String? {
    var code: SecCode?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                                        &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
}

let delegate = HelperListenerDelegate()
let listener = NSXPCListener(machServiceName: HelperInfo.machServiceName)
listener.delegate = delegate
listener.resume()
RunLoop.main.run()
