import AppKit
import SiteBlockCore

/// An app the user can pick for blocking.
struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    var id: String { bundleID.lowercased() }
}

/// Discovers candidate apps for the "Add app…" picker: everything in /Applications and
/// ~/Applications (top level only) plus currently running regular apps (catches things installed
/// elsewhere). SiteBlock itself and the core system apps in `AppBlockPolicy.neverBlock` are
/// excluded so they are never even offered (the enforcer refuses them independently).
enum InstalledApps {

    /// Filesystem + Launch Services work: call off the main thread.
    static func discover() -> [InstalledApp] {
        var byID: [String: InstalledApp] = [:]
        let fm = FileManager.default
        var dirs = [URL(fileURLWithPath: "/Applications")]
        dirs.append(fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications"))
        for dir in dirs {
            let items = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil,
                                                     options: [.skipsHiddenFiles])) ?? []
            for url in items where url.pathExtension == "app" {
                if let app = installedApp(at: url) { byID[app.id] = app }
            }
        }
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            if let url = running.bundleURL, let app = installedApp(at: url) { byID[app.id] = app }
        }
        let selfID = Bundle.main.bundleIdentifier?.lowercased()
        return byID.values
            .filter { AppBlockPolicy.isBlockable($0.id) && $0.id != selfID }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func installedApp(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: id, name: name)
    }

    /// Where each of `bundleIDs` is installed, keyed by bundle id (apps no longer installed are
    /// absent). A Launch Services lookup per id — call off the main thread, once per list change.
    static func paths(forBundleIDs bundleIDs: [String]) -> [String: String] {
        var result: [String: String] = [:]
        for id in bundleIDs {
            result[id] = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)?.path
        }
        return result
    }

    /// Finder icons for resolved app paths (see `paths(forBundleIDs:)`), keyed by bundle id.
    /// Icon loads are served from the icon cache; the slow part is the lookup above.
    static func icons(forPaths paths: [String: String]) -> [String: NSImage] {
        paths.mapValues { NSWorkspace.shared.icon(forFile: $0) }
    }
}
