import Foundation

/// Renders, parses and edits the SiteBlock-managed region of an `/etc/hosts`-style file.
///
/// All managed lines live between two sentinel markers. Editing only ever touches the region
/// between (and including) the markers — everything outside is preserved byte-for-byte. Each
/// blocked host is mapped to `127.0.0.1` (IPv4) and `::1` (IPv6) — the loopback address — so the
/// request is redirected to this machine, where the local blocked-page server can answer `http`
/// requests. (`https` requests show the browser's own security warning; see the discussion.)
public enum HostsFile {

    public static let beginMarker = "# >>> SiteBlock managed block >>>"
    public static let endMarker = "# <<< SiteBlock managed block <<<"
    static let notice = "# Managed by SiteBlock. Do not edit between these markers."

    /// The loopback IPv4 address blocked hosts are redirected to.
    static let loopbackIPv4 = "127.0.0.1"

    /// The managed region text (markers included) for the given hosts, without a trailing newline.
    public static func renderRegion(_ hosts: [String]) -> String {
        var lines = [beginMarker, notice]
        for host in hosts {
            lines.append("\(loopbackIPv4) \(host)")
            lines.append("::1 \(host)")
        }
        lines.append(endMarker)
        return lines.joined(separator: "\n")
    }

    /// Return `content` with the managed region set to exactly `hosts`. Any pre-existing managed
    /// region(s) are stripped first and a single fresh region is appended, so the result always
    /// contains exactly one region even if the input was somehow malformed (e.g. a duplicated
    /// begin marker). If `hosts` is empty, the region is simply removed.
    public static func applying(_ hosts: [String], to content: String) -> String {
        let cleaned = removing(from: content)
        guard !hosts.isEmpty else { return cleaned }

        let region = renderRegion(hosts)
        if cleaned.isEmpty {
            return region + "\n"
        }
        let base = cleaned.hasSuffix("\n") ? cleaned : cleaned + "\n"
        return base + region + "\n"
    }

    /// Return `content` with every managed region (and its markers) removed. Content outside the
    /// regions is preserved. No-op if there is no region. Handles duplicated/nested markers by
    /// removing each complete begin…end span until none remain.
    public static func removing(from content: String) -> String {
        var lines = splitLines(content)
        while let range = regionLineRange(in: lines) {
            lines.removeSubrange(range)
        }
        return lines.joined(separator: "\n")
    }

    /// The hosts currently listed in the managed region, in order, deduplicated.
    public static func managedHosts(in content: String) -> [String] {
        let lines = splitLines(content)
        guard let range = regionLineRange(in: lines) else { return [] }
        var hosts: [String] = []
        var seen = Set<String>()
        let prefix = "\(loopbackIPv4) "
        for line in lines[range] {
            guard line.hasPrefix(prefix) else { continue }
            let host = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            if !host.isEmpty, !seen.contains(host) {
                seen.insert(host)
                hosts.append(host)
            }
        }
        return hosts
    }

    // MARK: - Internals

    /// The inclusive line-index range of the first managed region (begin marker … end marker),
    /// or nil. Callers loop to strip multiple regions.
    private static func regionLineRange(in lines: [String]) -> Range<Int>? {
        guard let begin = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == beginMarker }),
              let end = lines[begin...].firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == endMarker })
        else { return nil }
        return begin..<(end + 1)
    }

    private static func splitLines(_ content: String) -> [String] {
        content.components(separatedBy: "\n")
    }
}

/// File-backed application of the managed hosts region. The path is injectable so tests operate
/// on a temp file and the app/helper point it at `/etc/hosts`.
public struct HostsFileWriter {

    public let path: URL

    public init(path: URL) {
        self.path = path
    }

    /// Convenience for the real system hosts file.
    public static var system: HostsFileWriter {
        HostsFileWriter(path: URL(fileURLWithPath: "/etc/hosts"))
    }

    /// Read current content (empty string if the file does not exist yet).
    public func read() throws -> String {
        guard FileManager.default.fileExists(atPath: path.path) else { return "" }
        return try String(contentsOf: path, encoding: .utf8)
    }

    /// Apply `hosts` to the managed region and write atomically. Empty `hosts` removes the region.
    public func apply(_ hosts: [String]) throws {
        let updated = HostsFile.applying(hosts, to: try read())
        try writeAtomically(updated)
    }

    /// Remove the managed region and write atomically.
    public func removeRegion() throws {
        let updated = HostsFile.removing(from: try read())
        try writeAtomically(updated)
    }

    /// The hosts currently in the managed region on disk.
    public func currentManagedHosts() throws -> [String] {
        HostsFile.managedHosts(in: try read())
    }

    private func writeAtomically(_ content: String) throws {
        // Data.write(.atomic) writes to a temp file in the same volume and renames into place,
        // so a crash mid-write can never leave a corrupted hosts file. The rename creates a new
        // inode, so we capture the existing POSIX permissions first and restore them afterwards —
        // otherwise /etc/hosts could end up with the wrong mode (it should stay 0644 root:wheel).
        let existingPermissions = try? FileManager.default
            .attributesOfItem(atPath: path.path)[.posixPermissions] as? NSNumber

        try Data(content.utf8).write(to: path, options: .atomic)

        if let permissions = existingPermissions {
            try? FileManager.default.setAttributes(
                [.posixPermissions: permissions], ofItemAtPath: path.path)
        }
    }
}
