import SwiftUI
import ServiceManagement
import SiteBlockCore

/// The menu bar popover: master toggle, add-domain field, the domain list, the blocked-app list
/// and the gate settings — with the gated countdown/confirm UI surfacing whenever a weaken action
/// is pending. Resizable from the bottom-right grip; the size is remembered.
struct MenuBarView: View {

    @ObservedObject var model: AppModel
    @State private var newDomain: String = ""
    @State private var showSettings = false
    @AppStorage("popoverWidth") private var width: Double = 340
    @AppStorage("popoverHeight") private var height: Double = 560
    @State private var installedApps: [InstalledApp] = []
    /// Resolved icons for the blocked apps, keyed by bundle id — filled off-main, never in `body`.
    @State private var appIcons: [String: NSImage] = [:]

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
            // The lists take whatever height the user gives the window.
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    domainList
                    appSection
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
            settingsSection
            if let status = model.status {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            footer
        }
        .padding(14)
        .frame(width: width, height: height)
        .overlay(alignment: .bottomTrailing) {
            ResizeGrip(width: $width, height: $height)
        }
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
            Text("SiteBlock couldn’t confirm the block is enforced (usually the privileged helper "
                 + "isn’t approved). Approve SiteBlock under “Allow in the Background,” then Retry.")
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
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.domains, id: \.self) { domain in
                        domainRow(domain)
                    }
                }
            }
        }
    }

    private func domainRow(_ domain: String) -> some View {
        removableRow(isPending: model.pending == .removeDomain(domain),
                     pendingLabel: "Removing \(domain)",
                     count: model.blockedCount(for: domain),
                     countHelp: "Blocked attempts",
                     isPaused: model.isDomainPaused(domain),
                     onPause: { model.pauseDomain(domain) },
                     onResume: { Task { await model.resumeDomain(domain) } },
                     onRemove: { model.requestRemove(domain) }) {
            Text(domain).font(.body.monospaced())
        }
    }

    /// Blocked apps: an "Add app…" menu (instant) and the list with the same gated remove flow.
    /// App discovery and icon resolution hit the filesystem and Launch Services, so both run off
    /// the main thread once (per popover open / per list change) rather than in `body`.
    private var appSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Menu {
                if installedApps.isEmpty {
                    Text("No apps found")
                } else {
                    ForEach(installedApps) { app in
                        Button(app.name) { Task { await model.addApp(bundleID: app.bundleID, name: app.name) } }
                            .disabled(model.isAppBlocked(app.bundleID))
                    }
                }
            } label: {
                Label("Add app…", systemImage: "app.badge")
            }
            .task {
                installedApps = await Task.detached(priority: .userInitiated) { InstalledApps.discover() }.value
            }

            if !model.apps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(model.apps, id: \.bundleID) { app in
                        appRow(app)
                    }
                }
            }
        }
        .task(id: model.apps.map(\.bundleID)) {
            let ids = model.apps.map(\.bundleID)
            let paths = await Task.detached(priority: .utility) { InstalledApps.paths(forBundleIDs: ids) }.value
            appIcons = InstalledApps.icons(forPaths: paths)
        }
    }

    private func appRow(_ app: BlockedApp) -> some View {
        removableRow(isPending: model.pending == .removeApp(app.bundleID),
                     pendingLabel: "Removing \(app.name)",
                     count: model.blockedCount(forApp: app.bundleID),
                     countHelp: "Blocked launches",
                     isPaused: model.isAppPaused(app.bundleID),
                     onPause: { model.pauseApp(app.bundleID) },
                     onResume: { Task { await model.resumeApp(app.bundleID) } },
                     onRemove: { model.requestRemoveApp(app.bundleID) }) {
            appLabel(app)
        }
    }

    /// Icon + name for a blocked app; falls back to a placeholder glyph when the app is no longer
    /// installed, so a stale entry stays removable rather than rendering blank.
    private func appLabel(_ app: BlockedApp) -> some View {
        HStack(spacing: 6) {
            if let icon = appIcons[app.bundleID] {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "app.dashed")
            }
            Text(app.name)
        }
    }

    /// One list row for anything removable through the friction gate (a domain or an app): the
    /// label, the blocked tally, a pause/resume toggle and a trash button — or, while this row's
    /// removal is pending, the shared countdown/confirm controls. Pausing is only offered while
    /// blocking is off; resuming always works (it strengthens the block).
    @ViewBuilder
    private func removableRow<Content: View>(isPending: Bool,
                                           pendingLabel: String,
                                           count: Int,
                                           countHelp: String,
                                           isPaused: Bool,
                                           onPause: @escaping () -> Void,
                                           onResume: @escaping () -> Void,
                                           onRemove: @escaping () -> Void,
                                           @ViewBuilder label: () -> Content) -> some View {
        if isPending {
            VStack(alignment: .leading, spacing: 6) {
                label()
                pendingControls(label: pendingLabel)
            }
            .padding(6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.08)))
        } else {
            HStack {
                label()
                    .opacity(isPaused ? 0.45 : 1)
                if isPaused {
                    Text("Paused").font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                if count > 0 {
                    Text("\(count)×")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(countHelp)
                }
                if isPaused {
                    Button(action: onResume) { Image(systemName: "play.fill") }
                        .buttonStyle(.borderless)
                        .help("Resume blocking")
                } else {
                    Button(action: onPause) { Image(systemName: "pause.fill") }
                        .buttonStyle(.borderless)
                        .help(model.canPause ? "Pause — leave it out when blocking is on"
                                             : "Turn off blocking to pause")
                        .disabled(!model.canPause)
                }
                Button {
                    model.tick()
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove (requires the \(model.settings.cooldownMinutes)-minute wait)")
                .disabled(model.pending != nil)
            }
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

    /// The gate lengths. Editable only while blocking is off and nothing is pending; the steppers'
    /// ranges start at the 5/2-minute floor, so the gate can only be made stricter.
    private var settingsSection: some View {
        DisclosureGroup(isExpanded: $showSettings) {
            VStack(alignment: .leading, spacing: 6) {
                Stepper(value: Binding(get: { model.settings.cooldownMinutes },
                                       set: { model.setCooldownMinutes($0) }),
                        in: FrictionSettings.cooldownRange) {
                    Text("Wait before unblocking: \(model.settings.cooldownMinutes) min")
                }
                Stepper(value: Binding(get: { model.settings.windowMinutes },
                                       set: { model.setWindowMinutes($0) }),
                        in: FrictionSettings.windowRange) {
                    Text("Time to confirm: \(model.settings.windowMinutes) min")
                }
                Text(settingsHint).font(.caption2).foregroundStyle(.secondary)
            }
            .font(.caption)
            .disabled(!model.canChangeSettings)
            .padding(.top, 4)
        } label: {
            Text("Settings").font(.caption)
        }
    }

    private var settingsHint: String {
        if model.isBlocking { return "Turn off blocking to change these." }
        if model.pending != nil { return "Finish or cancel the pending removal first." }
        return "Minimums are \(FrictionSettings.cooldownRange.lowerBound) and "
            + "\(FrictionSettings.windowRange.lowerBound) minutes."
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
        // Keep the footer clear of the resize grip.
        .padding(.trailing, 12)
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

/// A bottom-right corner grip that resizes the popover. Deltas come from the mouse's SCREEN
/// position, not the gesture's translation: the menu bar window re-anchors itself under the
/// status item as it grows, which would feed back into a view-local translation and jitter.
private struct ResizeGrip: View {

    @Binding var width: Double
    @Binding var height: Double

    private static let minSize = CGSize(width: 320, height: 420)
    private static let maxWidth: CGFloat = 900

    @State private var dragStart: (size: CGSize, mouse: NSPoint)?

    var body: some View {
        Image(systemName: "arrow.down.right")
            .font(.system(size: 9, weight: .semibold))
            .foregroundStyle(.tertiary)
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
            .help("Drag to resize")
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        let mouse = NSEvent.mouseLocation
                        let start = dragStart ?? (CGSize(width: width, height: height), mouse)
                        dragStart = start
                        // Screen y grows upward, so dragging down makes the window taller.
                        let maxHeight = (NSScreen.main?.visibleFrame.height ?? 900) - 20
                        width = Double(min(max(start.size.width + mouse.x - start.mouse.x, Self.minSize.width),
                                           Self.maxWidth))
                        height = Double(min(max(start.size.height + start.mouse.y - mouse.y, Self.minSize.height),
                                            maxHeight))
                    }
                    .onEnded { _ in dragStart = nil }
            )
    }
}
