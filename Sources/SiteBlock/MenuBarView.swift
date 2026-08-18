import SwiftUI
import ServiceManagement
import SiteBlockCore

/// The menu bar popover: master toggle, add-domain field, the domain list, and the blocked-app
/// list — with the gated countdown/confirm UI surfacing whenever a weaken action is pending.
struct MenuBarView: View {

    @ObservedObject var model: AppModel
    @State private var newDomain: String = ""
    @State private var installedApps: [InstalledApp] = []

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            if model.blockingStatus == .notEnforced {
                notEnforcedBanner
            }
            masterToggle
            addField
            domainList
            appSection
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: 320)
        // Drive the friction countdown only while something is pending.
        .onReceive(tick) { _ in
            if model.pending != nil { model.tick() }
        }
    }

    // MARK: sections

    private var header: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            Text("SiteBlock").font(.headline)
            Spacer()
            Text(statusLabel)
                .font(.caption)
                .foregroundStyle(model.blockingStatus == .notEnforced ? Color.orange : .secondary)
        }
    }

    // The header must reflect *actual* enforcement, never just intent — otherwise it would show a
    // reassuring green lock while nothing is blocked (helper unapproved).
    private var statusIcon: String {
        switch model.blockingStatus {
        case .active: return "lock.fill"
        case .notEnforced: return "lock.trianglebadge.exclamationmark"
        case .off: return "lock.open"
        }
    }

    private var statusColor: Color {
        switch model.blockingStatus {
        case .active: return .green
        case .notEnforced: return .orange
        case .off: return .secondary
        }
    }

    private var statusLabel: String {
        switch model.blockingStatus {
        case .active: return "Blocking on"
        case .notEnforced: return "Not active"
        case .off: return "Blocking off"
        }
    }

    /// Shown when blocking is intended but not actually enforced — the one failure that would
    /// otherwise silently defeat the whole app. Gives the user the exact fix.
    private var notEnforcedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Blocking isn’t active", systemImage: "exclamationmark.triangle.fill")
                .font(.caption.bold())
                .foregroundStyle(.orange)
            Text("The privileged helper isn’t approved, so no sites are actually being blocked. "
                 + "Approve SiteBlock under “Allow in the Background,” then Retry.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            HStack {
                Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                Button("Retry") { Task { await model.retryEnforcement() } }
                    .buttonStyle(.borderedProminent)
            }
            .font(.caption)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }

    @ViewBuilder
    private var masterToggle: some View {
        if model.isBlocking {
            if model.pending == .turnOff {
                pendingControls(label: "Turning blocking off")
            } else {
                Button(role: .destructive) {
                    model.tick()
                    model.requestTurnOff()
                } label: {
                    Label("Turn off blocking…", systemImage: "hourglass")
                        .frame(maxWidth: .infinity)
                }
                // Only one weaken action at a time (e.g. don't start turn-off mid domain-removal).
                .disabled(model.pending != nil)
            }
        } else {
            Button {
                Task { await model.turnBlockingOn() }
            } label: {
                Label("Turn on blocking", systemImage: "lock.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var addField: some View {
        HStack {
            TextField("Add a domain (e.g. facebook.com)", text: $newDomain)
                .textFieldStyle(.roundedBorder)
                .onSubmit(add)
            Button("Add", action: add)
                .disabled(newDomain.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private var domainList: some View {
        Group {
            if model.domains.isEmpty {
                Text("No sites blocked yet. Add one above.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.domains, id: \.self) { domain in
                            domainRow(domain)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
        }
    }

    @ViewBuilder
    private func domainRow(_ domain: String) -> some View {
        if model.pending == .removeDomain(domain) {
            VStack(alignment: .leading, spacing: 6) {
                Text(domain).font(.body.monospaced())
                pendingControls(label: "Removing \(domain)")
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        } else {
            HStack {
                Text(domain).font(.body.monospaced())
                Spacer()
                if model.blockedCount(for: domain) > 0 {
                    Text("\(model.blockedCount(for: domain))×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Blocked attempts")
                }
                Button {
                    model.tick()
                    model.requestRemove(domain)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove (requires the 5-minute wait)")
                .disabled(model.pending != nil)
            }
        }
    }

    /// Blocked apps: an "Add app…" menu (instant) and the list with the same gated remove flow.
    private var appSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                if installedApps.isEmpty {
                    Text("No apps found")
                } else {
                    ForEach(installedApps) { app in
                        Button(app.name) { Task { await model.addApp(bundleID: app.bundleID, name: app.name) } }
                            .disabled(model.apps.contains { $0.bundleID.lowercased() == app.id })
                    }
                }
            } label: {
                Label("Add app…", systemImage: "app.badge")
            }
            .onAppear { installedApps = InstalledApps.discover() }

            if !model.apps.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(model.apps, id: \.bundleID) { app in
                            appRow(app)
                        }
                    }
                }
                .frame(maxHeight: 140)
            }
        }
    }

    @ViewBuilder
    private func appRow(_ app: BlockedApp) -> some View {
        if model.pending == .removeApp(app.bundleID) {
            VStack(alignment: .leading, spacing: 6) {
                appLabel(app)
                pendingControls(label: "Removing \(app.name)")
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        } else {
            HStack {
                appLabel(app)
                Spacer()
                if model.blockedCount(forApp: app.bundleID) > 0 {
                    Text("\(model.blockedCount(forApp: app.bundleID))×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help("Blocked launches")
                }
                Button {
                    model.tick()
                    model.requestRemoveApp(app.bundleID)
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove (requires the 5-minute wait)")
                .disabled(model.pending != nil)
            }
        }
    }

    /// Icon + name for a blocked app; falls back to a placeholder glyph when the app is no longer
    /// installed, so a stale entry stays removable rather than rendering blank.
    private func appLabel(_ app: BlockedApp) -> some View {
        HStack(spacing: 6) {
            if let icon = InstalledApps.icon(forBundleID: app.bundleID) {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
            }
            Text(app.name)
        }
    }

    /// The shared cooldown → confirm UI used by both turn-off and remove.
    @ViewBuilder
    private func pendingControls(label: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let cooldown = model.cooldownRemaining {
                Label("\(label) in \(format(cooldown))", systemImage: "hourglass")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Come back when the timer ends to confirm.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            } else if let window = model.windowRemaining {
                Label("Confirm within \(format(window))", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Button {
                    Task { await model.confirmPending() }
                } label: {
                    Text("Confirm — enter password").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            Button("Cancel", role: .cancel) { model.cancelPending() }
                .font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            Text(model.blockStats.total > 0
                 ? "\(model.blockStats.total) attempts blocked so far."
                 : "Blocks sites in every browser, and apps.")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .font(.caption)
        }
    }

    // MARK: actions

    private func add() {
        let value = newDomain
        newDomain = ""
        Task { await model.addDomain(value) }
    }

    private func format(_ interval: TimeInterval) -> String {
        let total = Int(interval.rounded(.up))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
