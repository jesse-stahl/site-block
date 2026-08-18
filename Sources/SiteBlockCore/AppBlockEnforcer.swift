import Foundation

/// A running process as seen by the enforcer: pid + absolute executable path.
public struct RunningProcess: Equatable, Sendable {
    public let pid: Int32
    public let executablePath: String
    public init(pid: Int32, executablePath: String) {
        self.pid = pid
        self.executablePath = executablePath
    }
}

/// Source of the live process table (libproc in the helper, a fake in tests).
public protocol ProcessListing {
    func runningProcesses() -> [RunningProcess]
}

/// Sends signals to processes (POSIX `kill(2)` in the helper, a fake in tests).
public protocol ProcessSignaling {
    /// Polite quit — SIGTERM. Lets Discord/Steam save state.
    func terminate(pid: Int32)
    /// Force quit — SIGKILL.
    func kill(pid: Int32)
}

/// The app-blocking engine, driven once per second by the root helper's `ProcessWatcher`.
///
/// Each `sweep` maps every process → outermost bundle root (`AppBundle.bundleRoot`) → bundle id
/// (cached per root; a plist read per process per second would be wasteful) and, for ids in the
/// blocked set: SIGTERM on first sight, SIGKILL once `forceKillAfter` has elapsed and it is still
/// alive. Matching is case-insensitive. The helper's own pid, `AppBlockPolicy.neverBlock` and any
/// extra `protectedBundleIDs` are never signalled, so neither a mis-click nor a hand-edited list
/// can lock the user out.
///
/// Attempt reporting: `sweep` returns the blocked bundle ids (deduplicated) of processes seen for
/// the FIRST time since the set was applied. `setBlockedBundleIDs` performs an immediate baseline
/// sweep that kills already-running matches silently — turning blocking on while Discord is open
/// is housekeeping, not a "blocked attempt". Re-applying an identical set is a no-op, so routine
/// re-pushes from the app never reset the escalation clock or swallow an in-flight attempt.
/// Not thread-safe: the owner must call it from one serial queue.
public final class AppBlockEnforcer {

    private let processes: ProcessListing
    private let signals: ProcessSignaling
    private let bundleIdentifier: (String) -> String?
    private let forceKillAfter: TimeInterval
    private let protected: Set<String>
    private let ownPID: Int32

    /// Exactly what was last applied (original casing, original order), for verification
    /// round-trips.
    public private(set) var blockedBundleIDs: [String] = []
    /// Lowercased id → the user's original casing, for matching and for reporting attempts.
    private var blocked: [String: String] = [:]
    /// pid → time SIGTERM was sent. A pid absent here has not been signalled yet.
    private var termSentAt: [Int32: Date] = [:]
    /// Bundle root → resolved id. Only successful lookups are cached: a transiently unreadable
    /// Info.plist (an app mid-self-update) must be retried next sweep, not remembered as "unknown"
    /// for the lifetime of the root daemon.
    private var idCache: [String: String] = [:]

    public init(processes: ProcessListing,
                signals: ProcessSignaling,
                bundleIdentifier: @escaping (String) -> String? = AppBundle.bundleIdentifier(atRoot:),
                forceKillAfter: TimeInterval = 3,
                protectedBundleIDs: Set<String> = [],
                ownPID: Int32) {
        self.processes = processes
        self.signals = signals
        self.bundleIdentifier = bundleIdentifier
        self.forceKillAfter = forceKillAfter
        self.protected = AppBlockPolicy.neverBlock.union(protectedBundleIDs.map { $0.lowercased() })
        self.ownPID = ownPID
    }

    /// Replace the blocked set and immediately kill any running matches (silently — no attempts).
    /// Returns `false` (and does nothing) if `ids` is exactly what is already applied.
    @discardableResult
    public func setBlockedBundleIDs(_ ids: [String], now: Date) -> Bool {
        guard ids != blockedBundleIDs else { return false }
        blockedBundleIDs = ids
        blocked = Dictionary(ids.map { ($0.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        termSentAt = [:]
        idCache = [:]   // an app updated in place may have a new id at the same root
        _ = run(now: now, countAttempts: false)
        return true
    }

    /// One enforcement pass. Returns the blocked bundle ids of NEWLY seen matching processes.
    @discardableResult
    public func sweep(now: Date) -> [String] {
        run(now: now, countAttempts: true)
    }

    private func run(now: Date, countAttempts: Bool) -> [String] {
        guard !blocked.isEmpty else { return [] }
        var alive = Set<Int32>()
        var attempts: [String] = []
        var reported = Set<String>()

        for process in processes.runningProcesses() where process.pid != ownPID {
            guard let root = AppBundle.bundleRoot(forExecutable: process.executablePath),
                  let id = cachedIdentifier(root)?.lowercased(),
                  let original = blocked[id], !protected.contains(id) else { continue }
            alive.insert(process.pid)

            if let sentAt = termSentAt[process.pid] {
                if now.timeIntervalSince(sentAt) >= forceKillAfter {
                    signals.kill(pid: process.pid)
                }
            } else {
                termSentAt[process.pid] = now
                signals.terminate(pid: process.pid)
                if countAttempts, reported.insert(id).inserted {
                    // Report with the user's original casing so stats/notifications look right.
                    attempts.append(original)
                }
            }
        }
        // Forget pids that have exited so a relaunch (even with a reused pid) is a fresh attempt.
        termSentAt = termSentAt.filter { alive.contains($0.key) }
        return attempts
    }

    private func cachedIdentifier(_ root: String) -> String? {
        if let cached = idCache[root] { return cached }
        guard let resolved = bundleIdentifier(root) else { return nil }
        idCache[root] = resolved
        return resolved
    }
}

/// JSON persistence for the helper's blocked-app set. Lives root-owned next to the stats file so
/// app blocking survives a reboot even if the menu bar app never launches — the same "the block
/// outlives the UI" guarantee `/etc/hosts` gives sites.
public struct BlockedAppsStore {

    private let store: JSONFileStore<[String]>
    public var url: URL { store.url }

    public init(url: URL) {
        store = JSONFileStore(url: url, empty: { [] })
    }

    /// Empty if nothing has been saved yet.
    public func load() throws -> [String] { try store.load() }

    public func save(_ bundleIDs: [String]) throws { try store.save(bundleIDs) }
}
