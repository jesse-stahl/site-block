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
            auth: PasswordAuth()
        )
        _model = StateObject(wrappedValue: model)

        // Startup: register the helper, enable launch-at-login, and enforce the saved block.
        Task { @MainActor in
            try? helper.registerHelperIfNeeded()
            LaunchAtLogin.setEnabled(true)
            await model.reconcileOnLaunch()
        }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(model: model)
        } label: {
            Image(systemName: model.isBlocking ? "lock.fill" : "lock.open")
        }
        .menuBarExtraStyle(.window)
    }
}
