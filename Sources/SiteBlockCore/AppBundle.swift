import Foundation

/// Maps a running process's executable path to the application bundle it belongs to.
///
/// The helper enforces app blocking on *every* process of a blocked app (Discord's GPU/renderer
/// helpers, Steam's `steamwebhelper`, …), so we resolve to the OUTERMOST bundle: the path prefix
/// before the first `/Contents/` segment. We deliberately do not key on a `.app` suffix — Steam's
/// real client runs from `…/Steam.AppBundle/Steam/Contents/MacOS/steam_osx`.
///
/// Only executables that live in some `Contents/MacOS/` directory count as "the app", though.
/// Bundles also ship tools that OTHER programs run — `Xcode.app/Contents/Developer/usr/bin/git`,
/// `clang`, `swift` — and blocking Xcode must not kill every `git` invoked from a terminal.
public enum AppBundle {

    private static let contentsSegment = "/Contents/"
    private static let executableSegment = "/Contents/MacOS/"

    /// The outermost bundle root containing `executablePath`, or nil if the executable is not an
    /// app/helper binary inside a `…/Contents/MacOS/…` bundle layout (bare binaries like
    /// `/usr/bin/ssh`, or toolchain binaries shipped under a bundle's `Contents/Developer`).
    public static func bundleRoot(forExecutable executablePath: String) -> String? {
        guard executablePath.contains(executableSegment),
              let range = executablePath.range(of: contentsSegment) else { return nil }
        let root = String(executablePath[..<range.lowerBound])
        return root.isEmpty ? nil : root
    }

    /// Reads `CFBundleIdentifier` from `<root>/Contents/Info.plist` (XML or binary). Nil if the
    /// plist is missing/unreadable or has no identifier — callers must treat nil as "unknown, do
    /// not kill" (never act on a guess).
    public static func bundleIdentifier(atRoot root: String) -> String? {
        let plistPath = (root as NSString).appendingPathComponent("Contents/Info.plist")
        guard let dict = NSDictionary(contentsOfFile: plistPath),
              let id = dict["CFBundleIdentifier"] as? String,
              !id.isEmpty else { return nil }
        return id
    }
}
