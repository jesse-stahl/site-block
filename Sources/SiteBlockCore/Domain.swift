import Foundation

/// Parsing and normalization of user-entered domains, plus expansion into the full
/// set of hosts that should be blocked (base + `www.` + common mobile/regional subdomains).
public enum Domain {

    /// Subdomain prefixes that are automatically covered when a domain is blocked,
    /// so the user does not have to enumerate them. `www` is included here.
    public static let autoSubdomains = ["www", "m", "mobile", "l", "web"]

    /// Normalize a raw user string into a canonical bare host, or `nil` if it is not a
    /// plausible domain. Strips scheme, path, port and a leading `www.`; lowercases and trims.
    ///
    /// Examples: `"https://www.Facebook.com/feed"` → `"facebook.com"`, `"  News.YC.com "` →
    /// `"news.yc.com"`, `"not a domain"` → `nil`.
    public static func normalize(_ raw: String) -> String? {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !host.isEmpty else { return nil }

        // Drop scheme (http://, https://, anything://).
        if let range = host.range(of: "://") {
            host = String(host[range.upperBound...])
        }
        // Drop userinfo (user:pass@host).
        if let at = host.lastIndex(of: "@") {
            host = String(host[host.index(after: at)...])
        }
        // Drop path / query / fragment.
        for sep in ["/", "?", "#"] {
            if let idx = host.firstIndex(of: Character(sep)) {
                host = String(host[..<idx])
            }
        }
        // Drop port.
        if let colon = host.firstIndex(of: ":") {
            host = String(host[..<colon])
        }
        // Strip a single leading "www." so expansion is canonical.
        if host.hasPrefix("www.") {
            host = String(host.dropFirst(4))
        }
        // Drop a trailing dot (FQDN form).
        if host.hasSuffix(".") {
            host = String(host.dropLast())
        }

        guard isValidHost(host) else { return nil }
        return host
    }

    /// Expand a canonical host into every host that should be written to the block list:
    /// the host itself plus each auto-subdomain prefixed to it. Deduplicated, stable order
    /// (base first, then subdomains in `autoSubdomains` order).
    public static func expand(_ host: String) -> [String] {
        var result: [String] = [host]
        var seen: Set<String> = [host]
        for prefix in autoSubdomains {
            let candidate = "\(prefix).\(host)"
            if !seen.contains(candidate) {
                seen.insert(candidate)
                result.append(candidate)
            }
        }
        return result
    }

    /// Convenience: normalize a raw input and expand it in one step. Returns an empty
    /// array if the input is not a valid domain.
    public static func blocklistEntries(for raw: String) -> [String] {
        guard let host = normalize(raw) else { return [] }
        return expand(host)
    }

    /// A host is valid if it has at least two dot-separated labels, each label is 1–63
    /// chars of `[a-z0-9-]` not starting/ending with a hyphen, and the final label (TLD)
    /// is at least two alphabetic characters.
    static func isValidHost(_ host: String) -> Bool {
        guard host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }

        for label in labels {
            guard (1...63).contains(label.count) else { return false }
            guard !label.hasPrefix("-"), !label.hasSuffix("-") else { return false }
            for ch in label where !(ch.isLowercaseASCIILetterOrDigit || ch == "-") {
                return false
            }
        }
        // TLD must be alphabetic and at least two chars.
        guard let tld = labels.last, tld.count >= 2,
              tld.allSatisfy({ $0.isLowercaseASCIILetter }) else { return false }
        return true
    }
}

private extension Character {
    var isLowercaseASCIILetter: Bool { self >= "a" && self <= "z" }
    var isLowercaseASCIILetterOrDigit: Bool { isLowercaseASCIILetter || (self >= "0" && self <= "9") }
}
