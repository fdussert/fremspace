import AppKit
import FremspaceCore
import SwiftUI

extension EditSession {
    /// Reads what Fremspace knows about itself and the Mac, and lists what needs the owner. About
    /// what runs: the file as saved, not the changes being made.
    func refreshAttention() {
        var facts = AttentionFacts()
        facts.accessibility = Permissions.accessibilityGranted
        facts.loadError = loadError
        facts.paused = engine.paused
        if case .free(let reason) = engine.status, reason != "Starting" {
            facts.idle = reason == Engine.noConfigurationReason ? .noConfiguration : .other(reason)
        }
        facts.sessionLocked = Engine.sessionIsLocked
        facts.moverMissing = !engine.moverHealth.isPresent
        facts.missingCalls = engine.missingCalls
        facts.config = saved
        facts.active = engine.activeConfigurationID
        facts.desktopCounts = desktopCounts
        if let active = saved.configurations.first(where: { $0.id == engine.activeConfigurationID }) {
            let apps = Set(active.displays.flatMap { $0.spaces.flatMap { $0.layout?.slots.flatMap { $0.rules.map(\.bundleID) } ?? [] } })
            facts.missingApps = apps.filter { !$0.isEmpty && NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil }
        }
        facts.takenShortcuts = takenShortcuts()
        facts.hyperOn = ShortcutCatalog.hyperOn
        facts.moverAvailable = engine.moverHealth.isAvailable
        facts.waitingDrawerWindows = engine.drawers.waitingCount
        facts.spacesSpanDisplays = !NSScreen.screensHaveSeparateSpaces
        facts.screenRecording = WindowPreviews.allowed
        CFPreferencesAppSynchronize("com.apple.dock" as CFString)
        facts.spacesOrderWarning = SpacesOrder.warning(mruSpaces: CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString))
        let items = attentionItems(facts)
        // Published only when it changed: the window is not redrawn every few seconds for nothing.
        if items != attention { attention = items }
    }
}

extension AttentionLevel {
    var kind: Status.Kind {
        switch self {
        case .blocking: return .error
        case .warning: return .warning
        case .note: return .info
        }
    }
}

/// What needs the owner, most serious first, each with its way out; then what runs now.
struct StatusPage: View {
    @ObservedObject var session: EditSession
    let actions: SettingsActions

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if session.attention.isEmpty {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: Status.Kind.success.symbol).font(.title2).foregroundColor(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Nothing needs you").font(.headline)
                        Text("Permissions, the config file, desktops and shortcuts are as Fremspace expects.")
                            .foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(session.attention, id: \.id) { item in row(item) }
                }
            }
            PageSection("What runs") {
                fact("Configuration", applied)
                ForEach(session.connected, id: \.identity) { display in
                    fact(session.engine.displayName(display.identity), session.desktopCounts[display.identity].map { counted($0, "desktop") } ?? "desktops not read")
                }
                fact("Fremspace", AppVersion.current)
            }
        }
    }

    private var applied: String {
        switch session.engine.status {
        case .running(let configuration): return "\u{201C}\(configuration)\u{201D}, applied"
        case .paused: return "Paused"
        case .free(let reason): return "None applied: \(reason)"
        }
    }

    private func fact(_ name: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(name).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 8)
            Text(value).foregroundColor(.secondary).multilineTextAlignment(.trailing)
        }
    }

    private func row(_ item: AttentionItem) -> some View {
        let kind = item.level.kind
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: kind.symbol).foregroundColor(kind.color).frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title).fontWeight(.semibold)
                Text(item.detail).font(.callout).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            if let fix = item.fix {
                Button(verb(fix)) { run(fix) }
                    .accessibilityLabel("\(verb(fix)): \(item.title)")
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(item.level == .note ? Color.primary.opacity(0.05) : kind.color.opacity(0.12)))
        .accessibilityElement(children: .contain)
    }

    private func verb(_ fix: AttentionFix) -> String {
        switch fix {
        case .openAccessibilitySettings: return "Open Privacy settings"
        case .openDesktopSettings: return "Open Desktop & Dock"
        case .openScreenRecordingSettings: return "Open Privacy settings"
        case .openConfigFile: return "Open the file"
        case .resume: return "Resume"
        case .newConfiguration: return "New from connected displays"
        case .addDesktops: return "Add them"
        case .addFreeDesktop: return "Add a free desktop"
        case .showShortcuts: return "Show the shortcuts"
        case .showDesktop: return "Show the slot"
        }
    }

    private func run(_ fix: AttentionFix) {
        switch fix {
        case .openAccessibilitySettings:
            open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        case .openDesktopSettings:
            open("x-apple.systempreferences:com.apple.Desktop-Settings.extension")
        case .openScreenRecordingSettings:
            WindowPreviews.openSettings()
        case .openConfigFile:
            actions.openConfigFile()
        case .resume:
            session.engine.paused = false
        case .newConfiguration:
            session.newConfigurationFromConnectedDisplays()
            session.settingsPage = nil
        case .addDesktops:
            let added = session.engine.addMissingDesktops()
            session.refreshEnvironment()
            session.status = added
                ? Status(kind: .success, text: "Desktops added.")
                : Status(kind: .error, text: "Could not add them: use Mission Control (the + at the top right of each display).")
        case .addFreeDesktop(let configuration):
            // An edit like any other: it shows where the desktop went, and waits for Save.
            session.addFreeDesktop(to: configuration)
            session.settingsPage = nil
        case .showShortcuts:
            session.settingsPage = .shortcuts
        case .showDesktop(let configuration, let display, let desktop, let slot):
            guard let index = session.config.configurations.firstIndex(where: { $0.id == configuration }) else { return }
            var selection = Selection(configuration: index)
            selection.display = display
            selection.desktop = desktop
            selection.slot = slot
            session.selection = selection
            session.normalizeSelection()
            session.settingsPage = nil
        }
        session.refreshAttention()
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}
