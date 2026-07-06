import Foundation
import Combine

/// Applies the block to the system (via the privileged helper in production, a fake in tests).
public protocol HostsApplying {
    /// Set the system block to exactly these hosts.
    func apply(_ hosts: [String]) async throws
    /// Remove the block entirely.
    func removeBlock() async throws
}

/// Presents the secure Mac-password prompt used to confirm a weaken action.
public protocol PasswordAuthenticating {
    /// Returns `true` if the user successfully authenticated.
    func authenticate(reason: String) async -> Bool
}

/// The observable app state and all of SiteBlock's action logic, independent of SwiftUI so it can
/// be unit-tested. Enforces the asymmetric friction model:
///
/// - **Strengthen** (turn ON, add a domain) — applied immediately, no gate.
/// - **Weaken** (turn OFF, remove a domain) — routed through `FrictionMachine`: a 5-minute
///   cooldown, then a 2-minute confirmation window, then a Mac-password prompt.
///
/// Time is injected via `tick(now:)`, so the view drives a display timer while tests drive it
/// deterministically. Pending timers are never persisted and are reset by `reconcileOnLaunch()`.
@MainActor
public final class AppModel: ObservableObject {

    /// The weaken action awaiting its cooldown + confirmation.
    public enum PendingWeaken: Equatable {
        case turnOff
        case removeDomain(String)
    }

    @Published public private(set) var blockList: BlockList
    @Published public private(set) var friction: FrictionMachine
    @Published public private(set) var pending: PendingWeaken?
    @Published public private(set) var status: String?
    @Published public var now: Date

    private let store: BlockListStore
    private let hosts: HostsApplying
    private let auth: PasswordAuthenticating

    public init(store: BlockListStore,
                hosts: HostsApplying,
                auth: PasswordAuthenticating,
                friction: FrictionMachine = FrictionMachine(),
                now: Date = Date()) {
        self.store = store
        self.hosts = hosts
        self.auth = auth
        self.friction = friction
        self.now = now
        self.blockList = (try? store.load()) ?? BlockList()
    }

    public var isBlocking: Bool { blockList.isBlocking }
    public var domains: [String] { blockList.domains }

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

    /// Begin turning blocking off. Starts the friction cooldown.
    public func requestTurnOff() {
        guard blockList.isBlocking else { return }
        pending = .turnOff
        friction.request(now: now)
    }

    /// Begin removing a domain. Starts the friction cooldown.
    public func requestRemove(_ domain: String) {
        guard blockList.domains.contains(domain) else { return }
        pending = .removeDomain(domain)
        friction.request(now: now)
    }

    /// Cancel a pending weaken action and reset the timer.
    public func cancelPending() {
        friction.reset()
        pending = nil
    }

    /// Advance the clock. Called on a display timer by the view (and directly by tests). If the
    /// confirmation window has expired, the pending action is discarded (must be restarted).
    public func tick(now: Date) {
        self.now = now
        friction.tick(now: now)
        if pending != nil, case .idle = friction.state {
            pending = nil
            status = "Time's up — start over to unblock."
        }
    }

    /// Confirm the pending weaken action: requires the confirmation window to be open AND a
    /// successful password prompt. Returns `true` if the action was applied.
    @discardableResult
    public func confirmPending() async -> Bool {
        guard let pending else { return false }
        guard friction.canConfirm(now: now) else { return false }

        let reason: String
        switch pending {
        case .turnOff: reason = "turn off website blocking"
        case .removeDomain(let d): reason = "remove \(d) from your block list"
        }
        guard await auth.authenticate(reason: reason) else {
            status = "Authentication cancelled."
            return false
        }
        // Re-check the window survived the auth prompt, and consume the state.
        guard friction.confirm(now: now) else {
            self.pending = nil
            return false
        }

        switch pending {
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
        do { try await hosts.apply(blockList.allBlockedHosts()) }
        catch { status = "Couldn't update blocking: \(error.localizedDescription)" }
    }

    private func removeFromSystem() async {
        do { try await hosts.removeBlock() }
        catch { status = "Couldn't update blocking: \(error.localizedDescription)" }
    }
}
