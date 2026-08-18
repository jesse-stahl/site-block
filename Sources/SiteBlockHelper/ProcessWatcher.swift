import Foundation
import Darwin
import SiteBlockCore

/// Live process table via libproc — works from a root daemon with no GUI session (unlike
/// `NSWorkspace.runningApplications`, which only sees the caller's login session).
struct LibprocProcessLister: ProcessListing {
    func runningProcesses() -> [RunningProcess] {
        var count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        // Over-allocate: processes can spawn between the size query and the fill.
        var pids = [pid_t](repeating: 0, count: Int(count) * 2 + 16)
        count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }

        var buffer = [CChar](repeating: 0, count: Int(4 * MAXPATHLEN))
        var result: [RunningProcess] = []
        result.reserveCapacity(Int(count))
        for pid in pids.prefix(Int(count)) where pid > 0 {
            let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
            guard length > 0 else { continue }   // exited, or not permitted — skip
            result.append(RunningProcess(pid: pid, executablePath: String(cString: buffer)))
        }
        return result
    }
}

/// POSIX signals. Failures (process already gone) are ignored — the next sweep re-evaluates.
struct PosixSignaler: ProcessSignaling {
    func terminate(pid: Int32) { _ = Darwin.kill(pid, SIGTERM) }
    func kill(pid: Int32) { _ = Darwin.kill(pid, SIGKILL) }
}

/// Owns the enforcer, persists the blocked set, and runs the 1-second sweep timer — but ONLY while
/// there is something to enforce, so an empty set costs nothing. All enforcer access — and the
/// `onAttempt` callback — is on one serial queue (the enforcer itself is not thread-safe).
final class ProcessWatcher {

    private let queue = DispatchQueue(label: "today.siteblock.helper.processwatcher")
    private let enforcer: AppBlockEnforcer
    private let store: BlockedAppsStore
    private var timer: DispatchSourceTimer?
    /// Called (on `queue`) with each blocked bundle id whose launch was just stopped.
    private let onAttempt: (String) -> Void

    init(store: BlockedAppsStore, onAttempt: @escaping (String) -> Void) {
        self.store = store
        self.onAttempt = onAttempt
        self.enforcer = AppBlockEnforcer(
            processes: LibprocProcessLister(),
            signals: PosixSignaler(),
            protectedBundleIDs: ["today.siteblock.SiteBlock"],
            ownPID: getpid())
    }

    /// Restore the persisted set so app blocking survives a reboot even if the menu bar app
    /// hasn't launched yet (Discord/Steam auto-start at login).
    func start() {
        let saved = (try? store.load()) ?? []
        if !saved.isEmpty { setBlockedApps(saved) }
    }

    /// Replace the enforced set (kills running matches immediately, silently) and persist it.
    /// `completion` runs on `queue` once the set is live, with the persistence error if the
    /// write failed — the set is enforced in memory either way, but a caller must know that it
    /// will not survive a reboot. Re-applying an identical set is a no-op (no sweep, no write).
    func setBlockedApps(_ bundleIDs: [String], completion: ((Error?) -> Void)? = nil) {
        queue.async { [self] in
            var saveError: Error?
            if enforcer.setBlockedBundleIDs(bundleIDs, now: Date()) {
                do { try store.save(bundleIDs) } catch { saveError = error }
            }
            bundleIDs.isEmpty ? stopTimer() : startTimerIfNeeded()
            completion?(saveError)
        }
    }

    /// The set currently enforced (synchronous read for the XPC reply).
    func currentBlockedApps() -> [String] {
        queue.sync { enforcer.blockedBundleIDs }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: 1, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            for id in enforcer.sweep(now: Date()) { onAttempt(id) }
        }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}
