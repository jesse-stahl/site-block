import Foundation

/// Access to bundled resources for the app (e.g. the blocked page HTML).
public enum SiteBlockResources {
    /// The custom blocked page served for `http://` requests to blocked domains.
    /// Falls back to a minimal inline page if the bundled asset is unavailable.
    public static var blockedPageHTML: String {
        if let url = Bundle.module.url(forResource: "blocked", withExtension: "html"),
           let html = try? String(contentsOf: url, encoding: .utf8) {
            return html
        }
        return "<!doctype html><meta charset=utf-8><title>Blocked</title><h1>Blocked to keep you focused.</h1>"
    }
}
