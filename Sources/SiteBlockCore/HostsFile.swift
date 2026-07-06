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

    /// Return `content` with the managed region set to `hosts`. If a region already exists it is
    /// replaced in place; otherwise the region is appended. If `hosts` is empty, any existing
    /// region is removed instead (an empty region would be pointless).
    public static func applying(_ hosts: [String], to content: String) -> String {
        guard !hosts.isEmpty else { return removing(from: content) }

        let region = renderRegion(hosts)
        if let range = regionLineRange(in: content) {
            var lines = splitLines(content)
            lines.replaceSubrange(range, with: [region])
            return lines.joined(separator: "\n")
        }
        // Append, guaranteeing exactly one blank separation from prior content.
        if content.isEmpty {
            return region + "\n"
        }
        let base = content.hasSuffix("\n") ? content : content + "\n"
        return base + region + "\n"
    }

    /// Return `content` with the managed region (and its markers) removed. Content outside the
    /// region is preserved. No-op if there is no region.
    public static func removing(from content: String) -> String {
        guard let range = regionLineRange(in: content) else { return content }
        var lines = splitLines(content)
        lines.removeSubrange(range)
        return lines.joined(separator: "\n")
    }

    /// The hosts currently listed in the managed region, in order, deduplicated.
    public static func managedHosts(in content: String) -> [String] {
        guard let range = regionLineRange(in: content) else { return [] }
        let lines = splitLines(content)
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

    /// The inclusive line-index range of the managed region (begin marker … end marker), or nil.
    private static func regionLineRange(in content: String) -> Range<Int>? {
        let lines = splitLines(content)
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
