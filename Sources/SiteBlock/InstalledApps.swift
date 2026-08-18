import AppKit

/// An app the user can pick for blocking.
struct InstalledApp: Identifiable, Hashable {
    let bundleID: String
    let name: String
    let url: URL
    var id: String { bundleID.lowercased() }
}

/// Discovers candidate apps for the "Add app…" picker: everything in /Applications and
/// ~/Applications (top level only) plus currently running regular apps (catches things installed
/// elsewhere). SiteBlock itself and core system apps are excluded so the user can't lock
/// themselves out.
enum InstalledApps {

    /// Apps that must never be offered for blocking.
    static let excludedBundleIDs: Set<String> = [
        "today.siteblock.siteblock",
        "com.apple.finder", "com.apple.systempreferences", "com.apple.terminal",
        "com.apple.activitymonitor", "com.apple.dock", "com.apple.loginwindow",
        "com.apple.systemuiserver", "com.apple.controlcenter",
    ]

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
        return byID.values
            .filter { !excludedBundleIDs.contains($0.id) && $0.id != Bundle.main.bundleIdentifier?.lowercased() }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func installedApp(at url: URL) -> InstalledApp? {
        guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier, !id.isEmpty else { return nil }
        let name = (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? url.deletingPathExtension().lastPathComponent
        return InstalledApp(bundleID: id, name: name, url: url)
    }

    /// The Finder icon for an app, resolved by bundle id (nil if not installed any more).
    static func icon(forBundleID bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}
