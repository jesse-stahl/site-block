import Foundation

/// Maps a running process's executable path to the application bundle it belongs to.
///
/// The helper enforces app blocking on *every* process of a blocked app (Discord's GPU/renderer
/// helpers, Steam's `steamwebhelper`, …), so a process belongs to EVERY bundle that encloses it:
/// each path prefix before a `/Contents/` segment, innermost first. Neither the first nor the last
/// segment alone is safe — an app moved under some folder named `Contents` (or wrapped in a
/// decoy bundle) would resolve to a root with no Info.plist and slip through. We deliberately do
/// not key on a `.app` suffix — Steam's real client runs from
/// `…/Steam.AppBundle/Steam/Contents/MacOS/steam_osx`.
///
/// Only executables that live in some `Contents/MacOS/` directory count as "the app", though.
/// Bundles also ship tools that OTHER programs run — `Xcode.app/Contents/Developer/usr/bin/git`,
/// `clang`, `swift` — and blocking Xcode must not kill every `git` invoked from a terminal.
public enum AppBundle {

    private static let contentsSegment = "/Contents/"
    private static let executableSegment = "/Contents/MacOS/"

    /// Every candidate bundle root enclosing `executablePath`, innermost first — or empty if the
    /// executable is not an app/helper binary inside a `…/Contents/MacOS/…` bundle layout (bare
    /// binaries like `/usr/bin/ssh`, or toolchain binaries shipped under a bundle's
    /// `Contents/Developer`). Candidates that aren't real bundles simply have no Info.plist.
    public static func bundleRoots(forExecutable executablePath: String) -> [String] {
        guard let executable = executablePath.range(of: executableSegment, options: .backwards)
        else { return [] }
        var roots: [String] = []
        var remaining = executablePath[..<executable.lowerBound]
        while !remaining.isEmpty {
            roots.append(String(remaining))
            guard let enclosing = remaining.range(of: contentsSegment, options: .backwards) else { break }
            remaining = remaining[..<enclosing.lowerBound]
        }
        return roots
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
