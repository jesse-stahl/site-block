import Foundation

/// Shared identifiers and the XPC contract between the SiteBlock app and its privileged helper.
///
/// The helper is a `launchd` daemon registered once via `SMAppService`. Because it already runs
/// with privilege, the app can ask it to edit `/etc/hosts` without a per-action password — which
/// is what makes turning blocking ON and adding a domain instant. The friction on weaken actions
/// is enforced in the app (see `FrictionMachine`), not by the OS file permission prompt.
public enum HelperInfo {
    /// The Mach service name the helper registers and the app connects to. Must match the
    /// helper's launchd plist `MachServices` key.
    public static let machServiceName = "today.siteblock.helper"
}

/// The privileged operations the helper exposes over XPC. Kept intentionally tiny: all real
/// logic lives in `SiteBlockCore` (`HostsFile`), so the privileged surface is minimal.
@objc public protocol HostsControlProtocol {
    /// Apply the managed hosts region so exactly `hosts` are blocked. An empty array clears it.
    func apply(hosts: [String], withReply reply: @escaping (_ ok: Bool, _ error: String?) -> Void)

    /// Remove the managed hosts region entirely (used when blocking is turned off).
    func removeBlock(withReply reply: @escaping (_ ok: Bool, _ error: String?) -> Void)

    /// The hosts currently present in the managed region (for reconciliation on launch).
    func currentManagedHosts(withReply reply: @escaping (_ hosts: [String]) -> Void)

    /// The running block-attempt tallies as JSON-encoded `BlockStats` (a Data blob keeps the XPC
    /// surface to plist-safe types). Nil if encoding fails.
    func blockStats(withReply reply: @escaping (_ statsJSON: Data?) -> Void)
}
