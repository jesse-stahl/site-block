import Foundation

/// The state of a gated "weaken" action (turning blocking off, or removing a domain).
public enum FrictionState: Equatable {
    /// No weaken attempt in progress.
    case idle
    /// The cooldown is running; the action cannot be confirmed until `deadline`.
    case cooling(deadline: Date)
    /// The confirmation window is open until `windowEnds`; the user may now authenticate.
    case armed(windowEnds: Date)
    /// The action was confirmed within the window.
    case confirmed
}

/// Pure state machine enforcing SiteBlock's asymmetric friction on weaken actions.
///
/// Flow: `idle` → `request()` → `cooling` (5 min) → once the cooldown elapses → `armed`
/// (a 2-min confirmation window) → `confirm()` within the window → `confirmed`. If the window
/// closes first, it falls back to `idle` and the user must start over. `reset()` returns to
/// `idle` — used when the app quits or the Mac restarts (pending timers never persist).
///
/// The clock is injected (`now:` on every call) so the machine is fully deterministic and
/// testable. Strengthening actions (turn ON, add a domain) never touch this machine.
public struct FrictionMachine {

    public let cooldown: TimeInterval
    public let window: TimeInterval

    public private(set) var state: FrictionState = .idle

    /// - Parameters:
    ///   - cooldown: seconds to wait before the confirmation window opens (default 5 minutes).
    ///   - window: seconds the confirmation window stays open (default 2 minutes).
    public init(cooldown: TimeInterval = 5 * 60, window: TimeInterval = 2 * 60) {
        self.cooldown = cooldown
        self.window = window
    }

    /// Begin a weaken attempt. Only starts the cooldown from `idle`; a no-op if one is already
    /// in progress (so repeated clicks don't reset or extend the timer).
    public mutating func request(now: Date) {
        guard case .idle = state else { return }
        state = .cooling(deadline: now.addingTimeInterval(cooldown))
    }

    /// Recompute the state for the current time: `cooling` → `armed` when the cooldown elapses,
    /// `armed` → `idle` when the window closes. Call before reading state for display.
    public mutating func tick(now: Date) {
        state = resolved(at: now)
    }

    /// Attempt to confirm the weaken action. Succeeds only while `armed` and within the window.
    /// Returns `true` and moves to `confirmed`; otherwise returns `false` and updates state
    /// (e.g. an expired window drops back to `idle`; an early attempt during cooldown stays
    /// `cooling`).
    public mutating func confirm(now: Date) -> Bool {
        state = resolved(at: now)
        if case .armed = state {
            state = .confirmed
            return true
        }
        return false
    }

    /// Return to `idle`, cancelling any pending timer. Called on app quit / restart.
    public mutating func reset() {
        state = .idle
    }

    /// Seconds left in the cooldown, or `nil` if not currently cooling.
    public func remainingCooldown(now: Date) -> TimeInterval? {
        guard case .cooling(let deadline) = resolved(at: now) else { return nil }
        return max(0, deadline.timeIntervalSince(now))
    }

    /// Seconds left in the confirmation window, or `nil` if the window is not open.
    public func remainingWindow(now: Date) -> TimeInterval? {
        guard case .armed(let windowEnds) = resolved(at: now) else { return nil }
        return max(0, windowEnds.timeIntervalSince(now))
    }

    /// Whether the action can be confirmed right now.
    public func canConfirm(now: Date) -> Bool {
        if case .armed = resolved(at: now) { return true }
        return false
    }

    // MARK: - Internals

    /// The state as it should be at `now`, applying any due time-based transitions, without
    /// mutating `self`.
    private func resolved(at now: Date) -> FrictionState {
        switch state {
        case .idle, .confirmed:
            return state
        case .cooling(let deadline):
            if now >= deadline {
                // Cooldown elapsed → window opens; if that window has also already closed,
                // fall through to idle.
                let windowEnds = deadline.addingTimeInterval(window)
                return now > windowEnds ? .idle : .armed(windowEnds: windowEnds)
            }
            return state
        case .armed(let windowEnds):
            return now > windowEnds ? .idle : state
        }
    }
}
