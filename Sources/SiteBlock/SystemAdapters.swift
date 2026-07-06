import Foundation
import ServiceManagement
import LocalAuthentication
import SiteBlockCore

/// Talks to the privileged helper over XPC to apply/remove the system block. Conforms to
/// `HostsApplying` so `AppModel` is agnostic about how blocking reaches `/etc/hosts`.
final class HelperClient: HostsApplying, @unchecked Sendable {

    enum HelperClientError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self {
            case .failed(let message): return message
            }
        }
    }

    private lazy var connection: NSXPCConnection = {
        let connection = NSXPCConnection(machServiceName: HelperInfo.machServiceName, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: HostsControlProtocol.self)
        connection.resume()
        return connection
    }()

    /// Register the helper daemon via SMAppService (the one-time admin approval at first launch).
    /// The plist ships in the app bundle at `Contents/Library/LaunchDaemons/`.
    func registerHelperIfNeeded() throws {
        let service = SMAppService.daemon(plistName: "\(HelperInfo.machServiceName).plist")
        if service.status != .enabled {
            try service.register()
        }
    }

    func apply(_ hosts: [String]) async throws {
        try await call { proxy, reply in proxy.apply(hosts: hosts, withReply: reply) }
    }

    func removeBlock() async throws {
        try await call { proxy, reply in proxy.removeBlock(withReply: reply) }
    }

    /// Read the hosts currently in the live managed region (via the helper) so `AppModel` can
    /// verify an apply actually landed. Surfaces connection failures as thrown errors.
    func currentManagedHosts() async throws -> [String] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[String], Error>) in
            let resumed = ResumeGuard()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                if resumed.claim() { continuation.resume(throwing: error) }
            }
            guard let control = proxy as? HostsControlProtocol else {
                if resumed.claim() { continuation.resume(throwing: HelperClientError.failed("Helper unavailable")) }
                return
            }
            control.currentManagedHosts { hosts in
                if resumed.claim() { continuation.resume(returning: hosts) }
            }
        }
    }

    /// Bridge an XPC call (completion-handler based) into async/await, surfacing both connection
    /// errors and helper-reported failures.
    private func call(_ body: @escaping (HostsControlProtocol, @escaping (Bool, String?) -> Void) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let resumed = ResumeGuard()
            let proxy = connection.remoteObjectProxyWithErrorHandler { error in
                if resumed.claim() { continuation.resume(throwing: error) }
            }
            guard let control = proxy as? HostsControlProtocol else {
                if resumed.claim() { continuation.resume(throwing: HelperClientError.failed("Helper unavailable")) }
                return
            }
            body(control) { ok, message in
                guard resumed.claim() else { return }
                if ok { continuation.resume() }
                else { continuation.resume(throwing: HelperClientError.failed(message ?? "Unknown helper error")) }
            }
        }
    }
}

/// Ensures a continuation is resumed exactly once even if both the error handler and the reply
/// fire (which XPC can do on a broken connection).
private final class ResumeGuard: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false
    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if done { return false }
        done = true
        return true
    }
}

/// Presents the secure Mac-password prompt via LocalAuthentication.
///
/// Note: `LAPolicy.deviceOwnerAuthentication` is the only policy that includes the device
/// password. On a Touch ID Mac the system prompt may offer Touch ID before falling back to the
/// password; LocalAuthentication does not expose a strict password-only policy. The deliberate
/// authentication gate (the discussion's intent) is preserved either way.
final class PasswordAuth: PasswordAuthenticating {
    func authenticate(reason: String) async -> Bool {
        let context = LAContext()
        context.localizedReason = reason
        var authError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authError) else {
            return false
        }
        return await withCheckedContinuation { continuation in
            context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in
                continuation.resume(returning: success)
            }
        }
    }
}

/// Manages launch-at-login for the app itself via SMAppService.
enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func setEnabled(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // Non-fatal: launch-at-login is a convenience, not required for blocking to work.
            NSLog("SiteBlock: launch-at-login toggle failed: \(error.localizedDescription)")
        }
    }
}
