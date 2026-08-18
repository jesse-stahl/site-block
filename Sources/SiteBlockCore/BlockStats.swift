import Foundation

/// Per-host tally of blocked access attempts.
public struct BlockStats: Codable, Equatable, Sendable {

    public var counts: [String: Int]

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    public var total: Int { counts.values.reduce(0, +) }
}

/// Thread-safe recorder of block events with per-host coalescing: one browser page-visit fires
/// many connection attempts (IPv4+IPv6, retries, subresources), so raw hits within `coalescing`
/// seconds of the previous recorded event for the same host count as the SAME event. Clock is
/// injected for deterministic tests.
public final class BlockEventRecorder: @unchecked Sendable {

    private let coalescing: TimeInterval
    private let clock: () -> Date
    private let lock = NSLock()

    /// Running per-host tallies.
    private var counts: [String: Int] = [:]
    /// Last time a hit was actually COUNTED (not coalesced away) for a host. Deliberately not
    /// persisted — it's transient dedup state, not stats.
    private var lastCounted: [String: Date] = [:]

    public init(coalescing: TimeInterval = 5, clock: @escaping () -> Date = { Date() }) {
        self.coalescing = coalescing
        self.clock = clock
    }

    /// Record an attempt for `host` (as seen in a Host header or SNI). Normalizes: lowercase,
    /// strip a trailing dot, strip a ":port" suffix. Ignores empty/invalid results. Returns true
    /// iff this produced a NEW counted event (not coalesced away).
    @discardableResult
    public func recordHit(host: String) -> Bool {
        guard let normalized = Self.normalize(host) else { return false }

        lock.lock()
        defer { lock.unlock() }

        let now = clock()
        if let last = lastCounted[normalized], now.timeIntervalSince(last) < coalescing {
            return false
        }
        lastCounted[normalized] = now
        counts[normalized, default: 0] += 1
        return true
    }

    /// Snapshot of the running tallies.
    public var stats: BlockStats {
        lock.lock()
        defer { lock.unlock() }
        return BlockStats(counts: counts)
    }

    /// Restore previously persisted tallies (e.g. helper restart). Replaces current counts.
    /// Coalescing state is intentionally left untouched — it's transient, not persisted.
    public func restore(_ stats: BlockStats) {
        lock.lock()
        defer { lock.unlock() }
        counts = stats.counts
    }

    /// Lowercase, strip a trailing dot, strip a trailing ":port". Returns nil for empty input.
    private static func normalize(_ raw: String) -> String? {
        var host = raw.lowercased()
        if let colonIndex = host.lastIndex(of: ":") {
            let portPart = host[host.index(after: colonIndex)...]
            if !portPart.isEmpty && portPart.allSatisfy({ $0.isNumber }) {
                host = String(host[host.startIndex..<colonIndex])
            }
        }
        if host.hasSuffix(".") { host.removeLast() }
        return host.isEmpty ? nil : host
    }
}

/// JSON persistence for BlockStats, mirroring BlockListStore (atomic write, returns empty on
/// missing file).
public struct BlockStatsStore {

    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    /// Load the persisted stats. Returns an empty default if the file does not exist yet.
    /// Throws only if the file exists but cannot be decoded.
    public func load() throws -> BlockStats {
        guard FileManager.default.fileExists(atPath: url.path) else { return BlockStats() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(BlockStats.self, from: data)
    }

    /// Persist the stats, creating the containing directory if needed. Written atomically.
    public func save(_ stats: BlockStats) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(stats).write(to: url, options: .atomic)
    }
}
