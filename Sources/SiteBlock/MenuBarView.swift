import SwiftUI
import SiteBlockCore

/// The menu bar popover: master toggle, add-domain field, and the domain list — with the gated
/// countdown/confirm UI surfacing whenever a weaken action is pending.
struct MenuBarView: View {

    @ObservedObject var model: AppModel
    @State private var newDomain: String = ""

    private let tick = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            Divider()
            masterToggle
            addField
            domainList
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
            if model.pending != nil { model.tick(now: Date()) }
        }
    }

    // MARK: sections

    private var header: some View {
        HStack {
            Image(systemName: model.isBlocking ? "lock.fill" : "lock.open")
                .foregroundStyle(model.isBlocking ? Color.green : Color.secondary)
            Text("SiteBlock").font(.headline)
            Spacer()
            Text(model.isBlocking ? "Blocking on" : "Blocking off")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var masterToggle: some View {
        if model.isBlocking {
            if model.pending == .turnOff {
                pendingControls(label: "Turning blocking off")
            } else {
                Button(role: .destructive) {
                    model.tick(now: Date())
                    model.requestTurnOff()
                } label: {
                    Label("Turn off blocking…", systemImage: "hourglass")
                        .frame(maxWidth: .infinity)
                }
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
                Button {
                    model.tick(now: Date())
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
            Text("Blocks across all browsers.")
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
