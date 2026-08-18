import Foundation

/// The persisted state of the blocker: the user's domains and whether blocking is currently on.
///
/// Deliberately does NOT include any pending-timer state — the friction cooldown/window is
/// transient and resets on quit/restart (see `FrictionMachine`), so it is never serialized.
public struct BlockList: Codable, Equatable {

    /// Canonical base domains the user has added (e.g. `facebook.com`), in insertion order.
    public private(set) var domains: [String]

    /// Whether blocking is currently active.
    public var isBlocking: Bool

    public init(domains: [String] = [], isBlocking: Bool = false) {
        self.domains = domains
        self.isBlocking = isBlocking
    }

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
