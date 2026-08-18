import Foundation

/// The persisted state of the blocker: the user's domains, blocked apps, and whether blocking is
/// currently on.
///
/// Deliberately does NOT include any pending-timer state — the friction cooldown/window is
/// transient and resets on quit/restart (see `FrictionMachine`), so it is never serialized.
public struct BlockList: Codable, Equatable {

    /// Canonical base domains the user has added (e.g. `facebook.com`), in insertion order.
    public private(set) var domains: [String]

    /// Apps the user has added, in insertion order.
    public private(set) var apps: [BlockedApp]

    /// Whether blocking is currently active.
    public var isBlocking: Bool

    public init(domains: [String] = [], apps: [BlockedApp] = [], isBlocking: Bool = false) {
        self.domains = domains
        self.apps = apps
        self.isBlocking = isBlocking
    }

    private enum CodingKeys: String, CodingKey { case domains, apps, isBlocking }

    /// Custom decoding so block lists saved before app blocking existed (no `apps` key) still load.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        domains = try c.decodeIfPresent([String].self, forKey: .domains) ?? []
        apps = try c.decodeIfPresent([BlockedApp].self, forKey: .apps) ?? []
        isBlocking = try c.decodeIfPresent(Bool.self, forKey: .isBlocking) ?? false
    }

    // MARK: domains

    /// Add a raw user-entered domain. Normalizes it and ignores invalid input or duplicates.
    /// Returns `true` if a new domain was added. This is a strengthen action — always instant.
    @discardableResult
    public mutating func add(_ raw: String) -> Bool {
        guard let host = Domain.normalize(raw), !domains.contains(host) else { return false }
        domains.append(host)
        return true
    }

    /// Remove a domain (matched against its canonical form). Returns `true` if one was removed.
    /// Gating this action is the caller's responsibility (via `FrictionMachine`).
    @discardableResult
    public mutating func remove(_ domain: String) -> Bool {
        let host = Domain.normalize(domain) ?? domain
        guard let idx = domains.firstIndex(of: host) else { return false }
        domains.remove(at: idx)
        return true
    }

    /// Every host that should be written to the hosts file: each domain expanded to its
    /// `www.`/common-subdomain variants, deduplicated across the whole list, order-stable.
    public func allBlockedHosts() -> [String] {
        var result: [String] = []
        var seen = Set<String>()
        for domain in domains {
            for host in Domain.expand(domain) where !seen.contains(host) {
                seen.insert(host)
                result.append(host)
            }
        }
        return result
    }

    // MARK: apps

    /// Add an app by bundle identifier. Trims whitespace; rejects empty ids/names and duplicates
    /// (bundle ids compare case-insensitively). Returns `true` if added. Strengthen — instant.
    @discardableResult
    public mutating func addApp(bundleID: String, name: String) -> Bool {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty, !displayName.isEmpty, indexOfApp(id) == nil else { return false }
        apps.append(BlockedApp(bundleID: id, name: displayName))
        return true
    }

    /// Remove an app by bundle identifier (case-insensitive). Returns `true` if one was removed.
    /// Gating this action is the caller's responsibility (via `FrictionMachine`).
    @discardableResult
    public mutating func removeApp(bundleID: String) -> Bool {
        guard let idx = indexOfApp(bundleID) else { return false }
        apps.remove(at: idx)
        return true
    }

    /// The bundle identifiers to hand to the helper for enforcement, in insertion order.
    public func blockedBundleIDs() -> [String] {
        apps.map(\.bundleID)
    }

    /// Display name for a blocked app, or nil if it isn't on the list.
    public func appName(for bundleID: String) -> String? {
        indexOfApp(bundleID).map { apps[$0].name }
    }

    private func indexOfApp(_ bundleID: String) -> Int? {
        let needle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return apps.firstIndex { $0.bundleID.lowercased() == needle }
    }
}

/// Loads and saves a `BlockList` as JSON. The file URL is injectable for testing.
public struct BlockListStore {

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// The default on-disk location: `~/Library/Application Support/SiteBlock/blocklist.json`.
    public static func defaultURL(fileManager: FileManager = .default) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SiteBlock", isDirectory: true)
            .appendingPathComponent("blocklist.json")
    }

    /// Load the persisted list. Returns an empty default if the file does not exist yet.
    /// Throws only if the file exists but cannot be decoded.
    public func load() throws -> BlockList {
        guard FileManager.default.fileExists(atPath: url.path) else { return BlockList() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BlockList.self, from: data)
    }

    /// Persist the list, creating the containing directory if needed. Written atomically.
    public func save(_ list: BlockList) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(list).write(to: url, options: .atomic)
    }
}
