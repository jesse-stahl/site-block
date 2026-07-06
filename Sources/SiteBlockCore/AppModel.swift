import Foundation
import Combine

/// Applies the block to the system (via the privileged helper in production, a fake in tests).
public protocol HostsApplying {
    /// Set the system block to exactly these hosts.
    func apply(_ hosts: [String]) async throws
    /// Remove the block entirely.
    func removeBlock() async throws
    /// The hosts currently enforced in the system's managed region. Used to *verify* that an
    /// `apply` actually landed — a call returning success doesn't prove the privileged helper ran
    /// (e.g. it hasn't been approved), so we read the live region back to confirm.
    func currentManagedHosts() async throws -> [String]
}

/// Presents the secure Mac-password prompt used to confirm a weaken action.
public protocol PasswordAuthenticating {
    /// Returns `true` if the user successfully authenticated.
    func authenticate(reason: String) async -> Bool
}

/// Fetches the block-attempt tallies (via the privileged helper in production, a fake in tests).
public protocol BlockStatsProviding {
    func fetchBlockStats() async throws -> BlockStats
}

/// Tells the user a blocked site was just hit (a notification banner in production, a fake in
/// tests).
public protocol BlockNotifying {
    /// - Parameters:
    ///   - domain: the block-list domain that was attempted (e.g. "facebook.com").
    ///   - count: the all-time number of blocked attempts for that domain.
    func notifyBlocked(domain: String, count: Int) async
}

/// The observable app state and all of SiteBlock's action logic, independent of SwiftUI so it can
/// be unit-tested. Enforces the asymmetric friction model:
///
/// - **Strengthen** (turn ON, add a domain) — applied immediately, no gate.
/// - **Weaken** (turn OFF, remove a domain) — routed through `FrictionMachine`: a 5-minute
///   cooldown, then a 2-minute confirmation window, then a Mac-password prompt.
///
/// Time comes from an injected `clock` closure (defaults to `Date()`), so the view can drive a
/// real display timer while tests drive it deterministically. Critically, the confirmation window
/// is re-evaluated against the clock *after* the (possibly slow) auth prompt returns, so a slow
/// authentication can never let an expired window confirm. Pending timers are never persisted and
/// are reset by `reconcileOnLaunch()`.
@MainActor
public final class AppModel: ObservableObject {

    /// The weaken action awaiting its cooldown + confirmation.
    public enum PendingWeaken: Equatable {
        case turnOff
        case removeDomain(String)
    }

    /// How enforcement in the *system* stands relative to the user's intent.
    public enum BlockingStatus: Equatable {
        /// Blocking is intentionally off.
        case off
        /// Blocking is on AND verified to be enforced in `/etc/hosts` right now.
        case active
        /// Blocking is on (intent) but the system write has NOT landed — nothing is actually
        /// blocked (typically the privileged helper isn't approved). The UI must surface this.
        case notEnforced
    }

    @Published public private(set) var blockList: BlockList
    @Published public private(set) var friction: FrictionMachine
    @Published public private(set) var pending: PendingWeaken?
    @Published public private(set) var status: String?
    /// Whether the last enforcement attempt was verified to have landed in the system. This is the
    /// *truth* about blocking, as opposed to `blockList.isBlocking`, which is only the user's intent.
    @Published public private(set) var systemBlockVerified: Bool = false
    /// The latest block-attempt tallies fetched from the helper (empty until the first refresh).
    @Published public private(set) var blockStats = BlockStats()
    /// The last observed time, refreshed on every `tick()` — used by the display helpers.
    @Published public private(set) var now: Date

    private let store: BlockListStore
    private let hosts: HostsApplying
    private let auth: PasswordAuthenticating
    private let statsProvider: BlockStatsProviding?
    private let notifier: BlockNotifying?
    private let clock: () -> Date
    /// Per-domain time of the last posted notification, for rate-limiting.
    private var lastNotified: [String: Date] = [:]
    /// Minimum gap between notifications for the same domain — a blocked page reload spree
    /// shouldn't buzz the user every few seconds.
    private let notificationInterval: TimeInterval

    public init(store: BlockListStore,
                hosts: HostsApplying,
                auth: PasswordAuthenticating,
                statsProvider: BlockStatsProviding? = nil,
                notifier: BlockNotifying? = nil,
                friction: FrictionMachine = FrictionMachine(),
                notificationInterval: TimeInterval = 60,
                clock: @escaping () -> Date = { Date() }) {
        self.store = store
        self.hosts = hosts
        self.auth = auth
        self.statsProvider = statsProvider
        self.notifier = notifier
        self.friction = friction
        self.notificationInterval = notificationInterval
        self.clock = clock
        self.now = clock()
        self.blockList = (try? store.load()) ?? BlockList()
    }

    public var isBlocking: Bool { blockList.isBlocking }
    public var domains: [String] { blockList.domains }

    /// The truthful blocking state for the UI: distinguishes "on and actually enforced" from
    /// "on but not enforced" (helper unapproved / write failed) so the app can never claim it's
    /// blocking when it isn't.
    public var blockingStatus: BlockingStatus {
        guard blockList.isBlocking else { return .off }
        return systemBlockVerified ? .active : .notEnforced
    }

    /// Re-attempt to enforce the current intent in the system. For the "Retry" action after the
    /// user approves the helper — deliberately does not touch the friction timer or any pending
    /// weaken action.
    public func retryEnforcement() async {
        if blockList.isBlocking { await pushToSystem() }
        else { await removeFromSystem() }
    }

    /// Re-check that the system still enforces the current intent, and self-heal if it doesn't.
    /// Called periodically: a verified-at-write block can be stripped later (a macOS update
    /// rewriting /etc/hosts, another hosts-managing tool, a manual sudo edit) and the UI must not
    /// keep claiming `.active`. Re-applying is a *strengthen* action, so healing is ungated —
    /// only weakening goes through the friction gate. No-op while blocking is off.
    public func verifyEnforcement() async {
        guard blockList.isBlocking else { return }
        let expected = blockList.allBlockedHosts()
        // Unreachable helper → we can no longer vouch for enforcement; pushToSystem below will
        // set the precise status message.
        let live = (try? await hosts.currentManagedHosts()) ?? []
        if Set(expected).isSubset(of: Set(live)) {
            systemBlockVerified = true
            return
        }
        systemBlockVerified = false
        await pushToSystem()
    }

    // MARK: - Strengthen actions (instant, ungated)

    /// Add a domain. Instant. Applies to the live system if blocking is on. No-op for invalid or
    /// duplicate input.
    public func addDomain(_ raw: String) async {
        guard blockList.add(raw) else {
            status = "That doesn't look like a valid domain."
            return
        }
        persist()
        status = nil
        if blockList.isBlocking {
            await pushToSystem()
        }
    }

    /// Turn blocking on. Instant, no gate.
    public func turnBlockingOn() async {
        guard !blockList.isBlocking else { return }
        blockList.isBlocking = true
        persist()
        await pushToSystem()
    }

    // MARK: - Weaken actions (gated: cooldown -> window -> password)

    /// Begin turning blocking off. Starts the friction cooldown. No-op if another weaken action
    /// is already in flight — otherwise the new action would inherit the in-progress timer and
    /// bypass its own cooldown.
    public func requestTurnOff() {
        guard blockList.isBlocking, pending == nil else { return }
        pending = .turnOff
        friction.request(now: clock())
    }

    /// Begin removing a domain. Starts the friction cooldown. No-op if another weaken action is
    /// already in flight (see `requestTurnOff`).
    public func requestRemove(_ domain: String) {
        guard blockList.domains.contains(domain), pending == nil else { return }
        pending = .removeDomain(domain)
        friction.request(now: clock())
    }

    /// Cancel a pending weaken action and reset the timer.
    public func cancelPending() {
        friction.reset()
        pending = nil
    }

    /// Advance the clock (called on a display timer by the view, and directly by tests). If the
    /// confirmation window has expired, the pending action is discarded (must be restarted).
    public func tick() {
        let current = clock()
        now = current
        friction.tick(now: current)
        if pending != nil, case .idle = friction.state {
            pending = nil
            status = "Time's up — start over to unblock."
        }
    }

    /// Confirm the pending weaken action: requires the confirmation window to be open AND a
    /// successful password prompt. The window is re-checked against the clock *after* auth
    /// returns, so a slow prompt can never let an expired window through. Returns `true` if the
    /// action was applied.
    @discardableResult
    public func confirmPending() async -> Bool {
        now = clock()
        guard let action = pending else { return false }
        guard friction.canConfirm(now: now) else { return false }

        let reason: String
        switch action {
        case .turnOff: reason = "turn off website blocking"
        case .removeDomain(let d): reason = "remove \(d) from your block list"
        }
        guard await auth.authenticate(reason: reason) else {
            status = "Authentication cancelled."
            return false
        }

        // The await above suspended the main actor: the user may have cancelled and started a
        // different weaken action while the prompt was up. Only proceed if the pending action is
        // still the exact one we authenticated for.
        guard self.pending == action else { return false }

        // Re-evaluate against the current time — the auth prompt may have outlasted the window.
        let afterAuth = clock()
        now = afterAuth
        friction.tick(now: afterAuth)
        guard friction.confirm(now: afterAuth) else {
            self.pending = nil
            if case .idle = friction.state { status = "Time's up — start over to unblock." }
            return false
        }

        switch action {
        case .turnOff:
            blockList.isBlocking = false
            persist()
            await removeFromSystem()
        case .removeDomain(let domain):
            blockList.remove(domain)
            persist()
            if blockList.isBlocking { await pushToSystem() }
        }
        friction.reset()
        self.pending = nil
        status = nil
        return true
    }

    // MARK: - Block statistics

    /// Whether we've fetched stats at least once. The first fetch only baselines: counts accrued
    /// while the app wasn't watching (or before this launch) must not fire a notification storm.
    private var statsBaselined = false

    /// All-time blocked attempts for a block-list domain, aggregated across its covered hosts
    /// (facebook.com + www.facebook.com + m.facebook.com + …).
    public func blockedCount(for domain: String) -> Int {
        Self.aggregate(blockStats, for: domain)
    }

    /// Fetch the latest tallies from the helper, publish them, and notify the user about domains
    /// whose counts grew since the last refresh (rate-limited per domain). Called on a timer by
    /// the app and directly by tests.
    public func refreshStats() async {
        guard let statsProvider else { return }
        guard let fresh = try? await statsProvider.fetchBlockStats() else { return }

        let previous = blockStats
        blockStats = fresh
        guard statsBaselined else {
            statsBaselined = true
            return
        }
        guard let notifier else { return }

        for domain in blockList.domains {
            let newCount = Self.aggregate(fresh, for: domain)
            guard newCount > Self.aggregate(previous, for: domain) else { continue }
            let currentTime = clock()
            if let last = lastNotified[domain], currentTime.timeIntervalSince(last) < notificationInterval {
                continue
            }
            lastNotified[domain] = currentTime
            await notifier.notifyBlocked(domain: domain, count: newCount)
        }
    }

    private static func aggregate(_ stats: BlockStats, for domain: String) -> Int {
        stats.counts.reduce(0) { sum, entry in
            entry.key == domain || entry.key.hasSuffix("." + domain) ? sum + entry.value : sum
        }
    }

    // MARK: - Lifecycle

    /// Called at launch (and after a restart): pending timers never survive, and the live system
    /// block is reconciled to the persisted state so blocking is enforced even before the UI is
    /// touched.
    public func reconcileOnLaunch() async {
        friction.reset()
        pending = nil
        if blockList.isBlocking {
            await pushToSystem()
        } else {
            await removeFromSystem()
        }
    }

    // MARK: - Display helpers

    public var cooldownRemaining: TimeInterval? { friction.remainingCooldown(now: now) }
    public var windowRemaining: TimeInterval? { friction.remainingWindow(now: now) }
    public var canConfirm: Bool { friction.canConfirm(now: now) }

    // MARK: - Internals

    private func persist() {
        do { try store.save(blockList) }
        catch { status = "Couldn't save your list: \(error.localizedDescription)" }
    }

    private func pushToSystem() async {
        do {
            let expected = blockList.allBlockedHosts()
            try await hosts.apply(expected)
            // Verify the write actually landed. `apply` returning without throwing does NOT prove
            // the privileged helper ran (an unapproved helper never starts, yet the XPC layer can
            // still resolve) — so read the live managed region back and confirm our hosts are there.
            let live = try await hosts.currentManagedHosts()
            if Set(expected).isSubset(of: Set(live)) {
                systemBlockVerified = true
                status = nil
            } else {
                systemBlockVerified = false
                status = "Blocking isn't active — approve SiteBlock's helper in Login Items, then Retry."
            }
        } catch {
            systemBlockVerified = false
            status = "Blocking isn't active — \(error.localizedDescription)"
        }
    }

    private func removeFromSystem() async {
        do {
            try await hosts.removeBlock()
            systemBlockVerified = false
        } catch {
            status = "Couldn't update blocking: \(error.localizedDescription)"
        }
    }
}
