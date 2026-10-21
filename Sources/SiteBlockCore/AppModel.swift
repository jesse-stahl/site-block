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

/// Applies the blocked-app set to the system (via the privileged helper in production, a fake in
/// tests). Mirrors `HostsApplying`: an apply must be verified by reading the live set back.
public protocol AppBlockApplying {
    /// Enforce exactly these bundle identifiers (empty clears app blocking).
    func applyBlockedApps(_ bundleIDs: [String]) async throws
    /// The bundle identifiers the helper is enforcing right now.
    func currentBlockedApps() async throws -> [String]
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
/// - **Strengthen** (turn ON, add or resume a domain/app) — applied immediately, no gate.
/// - **Weaken** (turn OFF, remove a domain/app) — routed through `FrictionMachine`: a cooldown
///   (5 min or longer, per `FrictionSettings`), then a confirmation window (2 min or longer), then
///   a Mac-password prompt.
/// - **Off-only** (pause a domain/app, change the gate lengths) — free, but only while blocking is
///   off, where there is nothing live to weaken. With blocking on they're unavailable: the way
///   there is turning blocking off, which pays the gate.
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
        /// Remove an app, identified by bundle identifier.
        case removeApp(String)
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
    /// Optional because app blocking is a later addition: when nil the model enforces hosts only,
    /// so every pre-existing caller behaves exactly as it did before.
    private let appBlocker: AppBlockApplying?
    private let statsProvider: BlockStatsProviding?
    private let notifier: BlockNotifying?
    private let clock: () -> Date
    /// Time of the last posted notification per target, for rate-limiting. Keyed by the domain
    /// for sites and by `BlockedApp.statsKey` for apps, so the two namespaces can't collide.
    private var lastNotified: [String: Date] = [:]
    /// Minimum gap between notifications for the same domain — a blocked page reload spree
    /// shouldn't buzz the user every few seconds.
    private let notificationInterval: TimeInterval

    public init(store: BlockListStore,
                hosts: HostsApplying,
                auth: PasswordAuthenticating,
                apps: AppBlockApplying? = nil,
                statsProvider: BlockStatsProviding? = nil,
                notifier: BlockNotifying? = nil,
                notificationInterval: TimeInterval = 60,
                clock: @escaping () -> Date = { Date() }) {
        self.store = store
        self.hosts = hosts
        self.auth = auth
        self.appBlocker = apps
        self.statsProvider = statsProvider
        self.notifier = notifier
        self.notificationInterval = notificationInterval
        self.clock = clock
        self.now = clock()
        let loaded = (try? store.load()) ?? BlockList()
        self.blockList = loaded
        self.friction = Self.machine(for: loaded.settings)
    }

    public var isBlocking: Bool { blockList.isBlocking }
    public var domains: [String] { blockList.domains }
    public var apps: [BlockedApp] { blockList.apps }
    public var settings: FrictionSettings { blockList.settings }

    public func isDomainPaused(_ domain: String) -> Bool { blockList.isDomainPaused(domain) }
    public func isAppPaused(_ bundleID: String) -> Bool { blockList.isAppPaused(bundleID) }

    /// Pausing an item and changing the gate lengths are only possible while blocking is off.
    public var canPause: Bool { !blockList.isBlocking }

    /// …and the gate lengths also not while a weaken action is mid-countdown, so a running timer
    /// is never shortened (or silently restarted) underneath the user.
    public var canChangeSettings: Bool { !blockList.isBlocking && pending == nil }

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
        guard blockList.isBlocking else {
            // Off is an intent too: a turn-off whose system removal partly failed (helper busy,
            // XPC drop) must not leave root killing the user's apps behind an "off" padlock.
            // Only the halves still live are touched, and this path is a weaken the user already
            // paid the gate for.
            let hostsLive = await hostsStillLive()
            let appsLive = await appsStillLive()
            if hostsLive || appsLive { await removeFromSystem(hosts: hostsLive, apps: appsLive) }
            return
        }
        // Unreachable helper → we can no longer vouch for enforcement; pushToSystem below will
        // set the precise status message. BOTH halves must match: a live hosts region with a
        // stripped app set is not "enforced" — but only the half that drifted is re-applied, so a
        // stuck app half never causes a privileged /etc/hosts rewrite every 5 seconds.
        let hostsOK = await hostsVerified()
        let appsOK = await appsVerified()
        if hostsOK && appsOK {
            systemBlockVerified = true
            return
        }
        systemBlockVerified = false
        await pushToSystem(hosts: !hostsOK, apps: !appsOK)
    }

    /// True if the live managed hosts region is exactly ours (unreachable helper → false).
    private func hostsVerified() async -> Bool {
        guard let live = try? await hosts.currentManagedHosts() else { return false }
        return Set(live) == Set(blockList.allBlockedHosts())
    }

    /// True if the helper's live app set is exactly ours (or app blocking isn't wired up).
    private func appsVerified() async -> Bool {
        guard let appBlocker else { return true }
        guard let live = try? await appBlocker.currentBlockedApps() else { return false }
        return Set(live) == Set(blockList.blockedBundleIDs())
    }

    private func hostsStillLive() async -> Bool {
        !((try? await hosts.currentManagedHosts()) ?? []).isEmpty
    }

    private func appsStillLive() async -> Bool {
        guard let appBlocker else { return false }
        return !((try? await appBlocker.currentBlockedApps()) ?? []).isEmpty
    }

    // MARK: - Strengthen actions (instant, ungated)

    /// Add a domain. Instant. Applies to the live system if blocking is on. No-op for invalid or
    /// duplicate input.
    public func addDomain(_ raw: String) async {
        guard blockList.add(raw) else {
            status = "That doesn't look like a valid domain."
            return
        }
        status = nil
        let saveError = persist()
        if blockList.isBlocking {
            await pushToSystem(apps: false)
        }
        surface(saveError)
    }

    /// Add an app by bundle identifier. Instant. Applies to the live system if blocking is on.
    public func addApp(bundleID: String, name: String) async {
        guard blockList.addApp(bundleID: bundleID, name: name) else {
            status = "That app couldn't be added."
            return
        }
        status = nil
        let saveError = persist()
        if blockList.isBlocking {
            await pushToSystem(hosts: false)
        }
        surface(saveError)
    }

    /// Resume a paused domain. A strengthen action — instant, and applied live if blocking is on.
    public func resumeDomain(_ domain: String) async {
        guard blockList.setDomainPaused(domain, false) else { return }
        status = nil
        let saveError = persist()
        if blockList.isBlocking { await pushToSystem(apps: false) }
        surface(saveError)
    }

    /// Resume a paused app. A strengthen action — instant, and applied live if blocking is on.
    public func resumeApp(_ bundleID: String) async {
        guard blockList.setAppPaused(bundleID, false) else { return }
        status = nil
        let saveError = persist()
        if blockList.isBlocking { await pushToSystem(hosts: false) }
        surface(saveError)
    }

    /// Turn blocking on. Instant, no gate.
    public func turnBlockingOn() async {
        guard !blockList.isBlocking else { return }
        blockList.isBlocking = true
        let saveError = persist()
        await pushToSystem()
        surface(saveError)
    }

    // MARK: - Off-only actions (free, but only while blocking is off)

    /// Pause a domain so the next "turn on" leaves it out. No-op while blocking is on.
    public func pauseDomain(_ domain: String) {
        guard canPause, blockList.setDomainPaused(domain, true) else { return }
        persist()
    }

    /// Pause an app so the next "turn on" leaves it out. No-op while blocking is on.
    public func pauseApp(_ bundleID: String) {
        guard canPause, blockList.setAppPaused(bundleID, true) else { return }
        persist()
    }

    /// Set the wait before a weaken action can be confirmed (clamped to
    /// `FrictionSettings.cooldownRange`). No-op unless `canChangeSettings`.
    public func setCooldownMinutes(_ minutes: Int) {
        guard canChangeSettings else { return }
        update(FrictionSettings(cooldownMinutes: minutes, windowMinutes: settings.windowMinutes))
    }

    /// Set how long the confirmation window stays open (clamped to `FrictionSettings.windowRange`).
    /// No-op unless `canChangeSettings`.
    public func setWindowMinutes(_ minutes: Int) {
        guard canChangeSettings else { return }
        update(FrictionSettings(cooldownMinutes: settings.cooldownMinutes, windowMinutes: minutes))
    }

    private func update(_ newSettings: FrictionSettings) {
        guard newSettings != blockList.settings else { return }
        blockList.settings = newSettings
        friction = Self.machine(for: newSettings)
        persist()
    }

    private static func machine(for settings: FrictionSettings) -> FrictionMachine {
        FrictionMachine(cooldown: settings.cooldown, window: settings.window)
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

    /// Begin removing an app. Starts the friction cooldown. No-op if another weaken action is
    /// already in flight (see `requestTurnOff`).
    public func requestRemoveApp(_ bundleID: String) {
        // Store the canonical id (as listed), so the pending state matches the row regardless of
        // the casing the caller passed.
        guard let app = blockList.app(for: bundleID), pending == nil else { return }
        pending = .removeApp(app.bundleID)
        friction.request(now: clock())
    }

    /// True if an app with this bundle identifier (any casing) is on the block list.
    public func isAppBlocked(_ bundleID: String) -> Bool {
        blockList.app(for: bundleID) != nil
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
        case .turnOff: reason = "turn off blocking"
        case .removeDomain(let d): reason = "remove \(d) from your block list"
        case .removeApp(let id): reason = "remove \(blockList.appName(for: id) ?? id) from your block list"
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

        // Clear any stale message first so a failure reported by the system update below is
        // what the user sees, not overwritten by a blanket reset afterwards.
        status = nil
        switch action {
        case .turnOff:
            blockList.isBlocking = false
            persist()
            await removeFromSystem()
        case .removeDomain(let domain):
            blockList.remove(domain)
            let saveError = persist()
            if blockList.isBlocking { await pushToSystem(apps: false) }
            surface(saveError)
        case .removeApp(let id):
            blockList.removeApp(bundleID: id)
            let saveError = persist()
            if blockList.isBlocking { await pushToSystem(hosts: false) }
            surface(saveError)
        }
        friction.reset()
        self.pending = nil
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

    /// All-time blocked launch attempts for a blocked app (tallied by the helper under the
    /// namespaced `app:` key so it can never collide with a domain).
    public func blockedCount(forApp bundleID: String) -> Int {
        blockStats.counts[BlockedApp.statsKey(for: bundleID)] ?? 0
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
            await notifyIfGrew(key: domain, label: domain, notifier: notifier,
                               before: Self.aggregate(previous, for: domain),
                               after: Self.aggregate(fresh, for: domain))
        }
        for app in blockList.apps {
            let key = BlockedApp.statsKey(for: app.bundleID)
            // The notifier's `domain` parameter is just the display label; the app name reads
            // naturally in the banner ("Blocked Discord — 3 times so far").
            await notifyIfGrew(key: key, label: app.name, notifier: notifier,
                               before: previous.counts[key] ?? 0, after: fresh.counts[key] ?? 0)
        }
    }

    /// Post one banner for `label` if its tally grew, rate-limited per `key`.
    private func notifyIfGrew(key: String, label: String, notifier: BlockNotifying,
                              before: Int, after: Int) async {
        guard after > before else { return }
        let currentTime = clock()
        if let last = lastNotified[key], currentTime.timeIntervalSince(last) < notificationInterval {
            return
        }
        lastNotified[key] = currentTime
        await notifier.notifyBlocked(domain: label, count: after)
    }

    /// Sum of the tallies for a domain and its subdomains. App tallies live in the same
    /// dictionary under `BlockedApp.statsKeyPrefix` and are skipped — a bundle id such as
    /// `com.example.app` must never fold into the site `example.app` by suffix.
    private static func aggregate(_ stats: BlockStats, for domain: String) -> Int {
        stats.counts.reduce(0) { sum, entry in
            guard !entry.key.hasPrefix(BlockedApp.statsKeyPrefix) else { return sum }
            return entry.key == domain || entry.key.hasSuffix("." + domain) ? sum + entry.value : sum
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

    /// Save the list. Returns (and shows) the failure message, if any, so a caller whose next
    /// step resets `status` on success can re-surface it via `surface(_:)`.
    @discardableResult
    private func persist() -> String? {
        do {
            try store.save(blockList)
            return nil
        } catch {
            let message = "Couldn't save your list: \(error.localizedDescription)"
            status = message
            return message
        }
    }

    /// Re-show a save failure that a successful system push cleared — otherwise the change is
    /// silently lost at the next launch. A push failure already showing outranks it: "blocking
    /// isn't active" is the more urgent news.
    private func surface(_ saveError: String?) {
        if let saveError, status == nil { status = saveError }
    }

    /// Enforce the current intent in the system: the hosts half and/or the app half, each
    /// attempted independently so a failure in one never leaves the other unapplied. Then verify
    /// BOTH by reading the live state back — `apply` returning without throwing does NOT prove
    /// the privileged helper ran (an unapproved helper never starts, yet the XPC layer can still
    /// resolve), so we require the live hosts region and the live app set to be EXACTLY what we
    /// asked for. Equality (not subset) matters for removals: a failed write that left the old,
    /// larger set live must not pass as "the removal landed".
    private func pushToSystem(hosts pushHosts: Bool = true, apps pushApps: Bool = true) async {
        var failure: String?
        if pushHosts {
            do { try await hosts.apply(blockList.allBlockedHosts()) }
            catch { failure = error.localizedDescription }
        }
        if pushApps, let appBlocker {
            do { try await appBlocker.applyBlockedApps(blockList.blockedBundleIDs()) }
            catch { failure = failure ?? error.localizedDescription }
        }
        if let failure {
            systemBlockVerified = false
            status = "Blocking isn't active — \(failure)"
            return
        }
        // Read back. Once the hosts half has failed the verdict is decided; skip the extra round trip.
        let hostsOK = await hostsVerified()
        let appsOK = hostsOK ? await appsVerified() : false
        if hostsOK && appsOK {
            systemBlockVerified = true
            status = nil
        } else {
            systemBlockVerified = false
            status = "Blocking isn't active — approve SiteBlock's helper in Login Items, then Retry."
        }
    }

    /// Clear the system block — both halves by default, or only the ones still live when healing.
    /// Each is attempted independently: a failed hosts removal must never leave the helper still
    /// killing apps (or vice versa) — that would be a partial weaken the user cannot see or retry.
    private func removeFromSystem(hosts removeHosts: Bool = true, apps removeApps: Bool = true) async {
        var failure: String?
        if removeHosts {
            do { try await hosts.removeBlock() }
            catch { failure = error.localizedDescription }
        }
        if removeApps, let appBlocker {
            do { try await appBlocker.applyBlockedApps([]) }
            catch { failure = failure ?? error.localizedDescription }
        }
        systemBlockVerified = false
        if let failure {
            status = Self.removalFailurePrefix + failure
        } else if status?.hasPrefix(Self.removalFailurePrefix) == true {
            // Healed: drop our own stale error, but leave any unrelated message alone.
            status = nil
        }
    }

    private static let removalFailurePrefix = "Couldn't update blocking: "
}
