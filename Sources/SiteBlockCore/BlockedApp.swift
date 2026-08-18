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

    /// The key under which blocked-launch attempts for an app are tallied in `BlockStats`.
    /// Namespaced with `app:` so it can never collide with a domain key, and lowercased because
    /// bundle identifiers are compared case-insensitively.
    public static func statsKey(for bundleID: String) -> String {
        "app:" + bundleID.lowercased()
    }
}
