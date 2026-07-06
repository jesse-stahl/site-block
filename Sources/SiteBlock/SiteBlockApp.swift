import SwiftUI
import SiteBlockCore

/// SiteBlock — a private menu bar website blocker with an asymmetric friction model.
///
/// Lives in the menu bar (no dock icon when `LSUIElement` is set in the app's Info.plist). On
/// launch it registers the privileged helper (one-time admin approval), enables launch-at-login,
/// and reconciles the live system block to the saved state so blocking survives restarts.
@main
struct SiteBlockApp: App {

    @StateObject private var model: AppModel
    private let helper: HelperClient

    init() {
        let helper = HelperClient()
        self.helper = helper
        let model = AppModel(
            store: BlockListStore(url: BlockListStore.defaultURL()),
            hosts: helper,
            auth: PasswordAuth(),
            statsProvider: helper,
            notifier: BlockNotificationBanner()
        )
        _model = StateObject(wrappedValue: model)

        // Startup: register the helper, enable launch-at-login, and enforce the saved block.
        Task { @MainActor in
            try? helper.registerHelperIfNeeded()
            LaunchAtLogin.setEnabled(true)
            await model.reconcileOnLaunch()

            // Poll the helper's block tallies so the menu shows live counts and a banner fires
            // when a blocked site is hit. 5s keeps the notification timely without meaningful
            // cost (a tiny local XPC round-trip).
            while !Task.isCancelled {
                await model.refreshStats()
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            // Reflect real enforcement: a warning badge when blocking is intended but not actually
            // active (helper unapproved), so the menu bar never shows a false "locked" state.
            Image(systemName: menuBarIcon)
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarIcon: String {
        switch model.blockingStatus {
        case .active: return "lock.fill"
        case .notEnforced: return "lock.trianglebadge.exclamationmark"
        case .off: return "lock.open"
        }
    }
}
