import Foundation

/// A macOS application on the block list. Identified by its bundle identifier (stable across
/// renames/moves, e.g. `com.hnc.Discord`); `name` is only for display.
public struct BlockedApp: Codable, Equatable, Hashable, Sendable {

    public let bundleID: String
    public let name: String

    public init(bundleID: String, name: String) {
        self.bundleID = bundleID
        self.name = name
    }

    /// Prefix that namespaces app tallies inside the domain-keyed `BlockStats`.
    public static let statsKeyPrefix = "app:"

    /// The key under which blocked-launch attempts for an app are tallied in `BlockStats`.
    /// Namespaced with `app:` so it can never be confused with a domain key (domain readers must
    /// skip keys carrying `statsKeyPrefix` — see `AppModel.aggregate`), and lowercased because
    /// bundle identifiers are compared case-insensitively.
    public static func statsKey(for bundleID: String) -> String {
        statsKeyPrefix + bundleID.lowercased()
    }
}

/// The single source of truth for "apps that must never be blocked" — SiteBlock itself and the
/// core session apps whose death would lock the user out. Shared by the picker (so they are never
/// offered), `BlockList` (so they can't be added by any path) AND the root enforcer (so a
/// hand-edited or corrupted list can never make the helper kill loginwindow every second).
public enum AppBlockPolicy {

    /// Lowercased bundle identifiers.
    public static let neverBlock: Set<String> = [
        "today.siteblock.siteblock",
        "com.apple.finder", "com.apple.systempreferences", "com.apple.terminal",
        "com.apple.activitymonitor", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.controlcenter",
    ]

    /// True if `bundleID` (any casing) may be blocked.
    public static func isBlockable(_ bundleID: String) -> Bool {
        !neverBlock.contains(bundleID.lowercased())
    }
}
