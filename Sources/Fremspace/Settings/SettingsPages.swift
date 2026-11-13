import AppKit
import FremspaceCore
import SwiftUI

/// Fremspace's own pages, listed in the sidebar under the configurations: what holds whatever the
/// configuration and the displays.
enum SettingsPage: String, CaseIterable, Identifiable {
    case status, general, shortcuts, scenes, layouts, share, maintenance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .status: return "Status"
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .scenes: return "Scenes"
        case .layouts: return "Layouts"
        case .share: return "Share"
        case .maintenance: return "Maintenance"
        }
    }

    var symbol: String {
        switch self {
        case .status: return "checklist"
        case .general: return "gearshape"
        case .shortcuts: return "keyboard"
        case .scenes: return "rectangle.3.group"
        case .layouts: return "square.grid.2x2"
        case .share: return "square.and.arrow.up"
        case .maintenance: return "wrench.and.screwdriver"
        }
    }

    /// Under the page's title: what it holds and when a change applies.
    var summary: String {
        switch self {
        case .status: return "What needs you, most serious first, and what runs now. Read again every few seconds."
        case .general: return "How Fremspace runs and what it does with windows, on every configuration. Changes apply when you save, except where marked \u{201C}At once\u{201D}."
        case .shortcuts: return "Click a shortcut and type the new one. ⌫ removes it, ⎋ cancels."
        case .scenes: return "Desktops that several displays show together: one shortcut, or one name in the palette, switches them all."
        case .layouts: return "Ready-made layouts and the ones you kept: for one desktop, or a whole desk seen before it is added."
        case .share: return "This configuration as a file for somebody else. A file from somebody else is added on the Layouts page."
        case .maintenance: return "Commands for now, and for when something went wrong. They act at once."
        }
    }

    /// The page is about one configuration, the one selected: its header says which and can change it.
    var isOfAConfiguration: Bool { self == .scenes || self == .layouts || self == .share }

    /// Beside the page's name in the sidebar.
    func badge(_ session: EditSession) -> String? {
        switch self {
        case .status:
            // Notes are not counted: they ask for nothing.
            let count = session.attention.filter { $0.level != .note }.count
            return count == 0 ? nil : "\(count)"
        case .shortcuts:
            // "Custom", not "changed": in a window that has Save, "changed" reads as "unsaved".
            let custom = session.config.shortcuts.count
            return custom == 0 ? nil : "\(custom) custom"
        case .general:
            return session.engine.paused ? "Paused" : nil
        case .scenes:
            let count = session.configuration?.scenes.count ?? 0
            return count == 0 ? nil : "\(count)"
        case .layouts, .share, .maintenance:
            return nil
        }
    }
}

/// One page of settings: its title stays put, its sections scroll under it. The switches of the
/// file are saved with Save, like the layouts; "Open at login", "Paused" and the commands act at once.
struct SettingsPageView: View {
    @ObservedObject var session: EditSession
    let page: SettingsPage
    let actions: SettingsActions
    /// Bumped after a switch that is not in the file, so the page reads its state again.
    @State private var refresh = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    PageTitle(session: session, page: page)
                    Text(page.summary).foregroundColor(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if page == .shortcuts {
                    // Dressed as what it is: with "Search" above the sidebar in the same window, a
                    // bare field named "Filter" was a second search field to tell from the first.
                    HStack(spacing: 5) {
                        Image(systemName: "line.3.horizontal.decrease").foregroundColor(.secondary)
                        TextField("Filter shortcuts", text: $session.shortcutFilter)
                            .textFieldStyle(.plain)
                            .accessibilityLabel("Filter the shortcuts")
                        if !session.shortcutFilter.isEmpty {
                            Button { session.shortcutFilter = "" } label: {
                                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                            }
                            .buttonStyle(.borderless)
                            .accessibilityLabel("Clear the filter")
                        }
                    }
                    .padding(.horizontal, 7).frame(width: 200, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.14), lineWidth: 1))
                }
                if page == .scenes, session.configuration != nil {
                    HowScenesWork(first: session.shortcutLabel("scene.1"))
                }
            }
            .padding(.horizontal, 24).padding(.top, 20).padding(.bottom, 14)
            .frame(maxWidth: 760, alignment: .leading)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) { content }
                        .padding(24)
                        .frame(maxWidth: 760, alignment: .leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onAppear { scrollToRevealed(proxy) }
                .onChange(of: session.revealed) { _ in scrollToRevealed(proxy) }
            }
        }
    }

    /// A search result led here: its row comes into view.
    private func scrollToRevealed(_ proxy: ScrollViewProxy) {
        guard let row = session.revealed else { return }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(row, anchor: .center) }
        }
    }

    private func marked(_ row: SettingRow) -> Revealable { Revealable(session: session, row: row) }

    /// The swap shortcuts, as the owner set them.
    private var swapHint: String {
        let left = session.shortcutLabel("slotSwapLeft"), right = session.shortcutLabel("slotSwapRight")
        return " To trade the places of two slots: \(left) and \(right) (and up, down)."
    }

    @ViewBuilder
    private var content: some View {
        switch page {
        case .status:
            StatusPage(session: session, actions: actions)
        case .general:
            PageSection(.generalFremspace) {
                SwitchRow(title: SettingRow.openAtLogin.title,
                          detail: "Fremspace starts with your session and puts every window back.",
                          atOnce: true,
                          isOn: Binding(
                            get: { session.engine.loginRestorer.opensAtLogin },
                            set: { on in
                                session.engine.loginRestorer.setOpensAtLogin(on)
                                refresh += 1
                            }))
                    .modifier(marked(.openAtLogin))
                SwitchRow(title: SettingRow.paused.title,
                          detail: "Nothing is moved while paused." + hint("pause"),
                          atOnce: true,
                          isOn: Binding(
                            get: { session.engine.paused },
                            set: { on in
                                session.engine.paused = on
                                refresh += 1
                            }))
                    .modifier(marked(.paused))
                if session.engine.updates.isAvailable {
                    SwitchRow(title: SettingRow.autoUpdates.title,
                              detail: "Fremspace reads the list of its versions on GitHub and tells you when there is a newer one. Nothing about you or this Mac is sent.",
                              atOnce: true,
                              isOn: Binding(
                                get: { session.engine.updates.automaticChecks() },
                                set: { on in
                                    session.engine.updates.setAutomaticChecks(on)
                                    refresh += 1
                                }))
                        .modifier(marked(.autoUpdates))
                    CommandRow(title: SettingRow.checkForUpdates.title,
                               detail: "Asks now, without waiting for the day's look.",
                               verb: "Check now", done: "Asked") { session.engine.updates.check?() }
                        .modifier(marked(.checkForUpdates))
                }
            }
            .id(refresh)
            PageSection(.generalFloating) {
                SwitchRow(title: SettingRow.noFloating.title,
                          detail: "A window of an app without a slot goes to a free desktop, also when you drop it there by hand.",
                          more: "A fixed-size window (a reminder) joins the desktop of its app. Dialogs and popups stay where they are, and Send to desktop still puts a window on a layout desktop.",
                          isOn: Binding(
                            get: { session.config.noFloating },
                            set: { on in
                                session.checkpoint()
                                session.config.noFloating = on
                            }))
                    .modifier(marked(.noFloating))
                if session.config.noFloating {
                    ForEach(session.config.configurations.filter { !hasFreeDesktop($0) }) { configuration in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: Status.Kind.warning.symbol).foregroundColor(.orange)
                            Text("\u{201C}\(configuration.name)\u{201D} has no free desktop: these windows have nowhere to go and stay where they are.")
                                .font(.callout).fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 4)
                            Button("Add a free desktop") { session.addFreeDesktop(to: configuration.id) }
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                    }
                }
            }
            PageSection(.generalSlots) {
                SwitchRow(title: SettingRow.resizeLayouts.title,
                          detail: "Resize a window by a side it shares with another slot: the layout follows, on the nearest clean fraction.",
                          more: "The new sizes are written to the configuration as you let go. Off: a locked window snaps back." + swapHint,
                          isOn: Binding(
                            get: { session.config.resizeLayouts },
                            set: { on in
                                session.checkpoint()
                                session.config.resizeLayouts = on
                            }))
                    .modifier(marked(.resizeLayouts))
            }
            PageSection(.generalDesktops) {
                SwitchRow(title: SettingRow.desktopNames.title,
                          detail: "For a second at the top of that display: out of the notch on a MacBook, under the menu bar elsewhere.",
                          isOn: Binding(
                            get: { session.config.desktopNames },
                            set: { on in
                                session.checkpoint()
                                session.config.desktopNames = on
                            }))
                    .modifier(marked(.desktopNames))
                SwitchRow(title: SettingRow.notchMap.title,
                          detail: "Rest the pointer on the notch: every display with its desktops and their apps; a click shows a desktop. Only a display with a notch has it.",
                          isOn: Binding(
                            get: { session.config.notchMap },
                            set: { on in
                                session.checkpoint()
                                session.config.notchMap = on
                            }))
                    .modifier(marked(.notchMap))
                SwitchRow(title: SettingRow.windowPreviews.title,
                          detail: "A picture of each window in the palette, the maps and the editor. It needs Screen Recording, which macOS asks for when you save.",
                          more: "The maps and the editor show a slot's window instead of its app's icon; the palette shows a larger picture of the selected window. The pictures stay in memory and are never written anywhere.",
                          isOn: Binding(
                            get: { session.config.windowPreviews },
                            set: { on in
                                session.checkpoint()
                                session.config.windowPreviews = on
                            }))
                    .modifier(marked(.windowPreviews))
                if session.saved.windowPreviews, session.attention.contains(where: { $0.id == "previews" }) {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: Status.Kind.warning.symbol).foregroundColor(.orange)
                        Text("macOS does not allow the pictures yet: switch Fremspace on under Screen & System Audio Recording, then quit and reopen it when macOS asks.")
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        Button("Open Privacy settings") { WindowPreviews.openSettings() }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
                }
            }
            PageSection(.generalCalls,
                        badge: session.config.fullScreenCalls.isEmpty ? nil : "\(session.config.fullScreenCalls.count) on") {
                VStack(alignment: .leading, spacing: 10) {
                // Once for the section: it is the same for every app.
                HelpText("The meeting window goes to full screen when the call starts. One you take out of full screen stays out.")
                ForEach(callApps, id: \.bundleID) { app in
                    SwitchRow(title: app.name, detail: "",
                              isOn: Binding(
                                get: { session.config.fullScreenCalls.contains(app.bundleID) },
                                set: { on in
                                    session.checkpoint()
                                    var apps = Set(session.config.fullScreenCalls)
                                    if on { apps.insert(app.bundleID) } else { apps.remove(app.bundleID) }
                                    session.config.fullScreenCalls = apps.sorted()
                                }))
                }
                }
                .modifier(marked(.fullScreenCalls))
            }
        case .shortcuts:
            ShortcutsEditor(session: session, actions: actions, filter: session.shortcutFilter)
        case .scenes:
            ScenesEditor(session: session)
        case .layouts:
            // Its own page (`LayoutsPage`): a grid and a preview beside it, not a column of sections.
            EmptyView()
        case .share:
            ShareEditor(session: session)
        case .maintenance:
            // Each line says what one gets, its button says the verb: "Re-apply the layouts" beside a
            // button "Re-apply" said it twice. The command's own name stays what the search finds
            // and what VoiceOver reads on the button.
            PageSection(.maintenanceLayouts) {
                command(.reapply, "Every window back in its slot and on its desktop", detail: hint("reapply"), verb: "Re-apply", action: actions.reapply)
                command(.restoreEverything, "As at login: the apps that have a slot opened, every window put back",
                        verb: "Restore", action: actions.restoreEverything)
            }
            PageSection(.maintenanceWindows) {
                command(.bringBack, "The windows of the drawers and those lost off screen, back in view", verb: "Bring back", action: actions.bringBack)
            }
            PageSection(.maintenanceFile) {
                command(.openConfigFile, "The file, in your default editor", verb: "Open", done: "Opened", action: actions.openConfigFile)
                command(.reloadConfig, "The file read again, after an edit by hand", verb: "Reload", done: "Reloaded", action: actions.reloadConfig)
            }
            PageSection(.maintenanceDiagnostics) {
                command(.copyDiagnostics, "Displays, desktops, windows and Fremspace's state, on the clipboard",
                        verb: "Copy", done: "Copied", action: actions.copyDiagnostics)
                command(.dumpWindows, "Every window Fremspace sees, in a file that opens",
                        verb: "Dump", done: "Written", action: actions.dumpWindows)
            }
        }
    }

    private func command(_ row: SettingRow, _ what: String, detail: String = "", verb: String, done: String = "Done",
                         action: @escaping () -> Void) -> some View {
        CommandRow(title: what, detail: detail.trimmingCharacters(in: .whitespaces), verb: verb, done: done, name: row.title, action: action)
            .modifier(marked(row))
    }

    /// The command's shortcut as the owner set it, to end a detail line; nothing when it has none.
    private func hint(_ id: String) -> String {
        guard let shortcut = ShortcutCatalog.effective(session.config.shortcuts)[id], shortcut.keyCode != nil else { return "" }
        return " " + ShortcutCatalog.label(shortcut)
    }

    private func hasFreeDesktop(_ configuration: Configuration) -> Bool {
        configuration.displays.contains { !$0.ignored && $0.spaces.contains { $0.layout == nil } }
    }
}

/// A page's name; for a page about one configuration, with that configuration, which the sidebar
/// no longer shows as selected, and a way to change it without leaving the page.
struct PageTitle: View {
    @ObservedObject var session: EditSession
    let page: SettingsPage

    var body: some View {
        let several = session.config.configurations.count > 1
        // Layouts are for any configuration: the page names one only when there is a choice to make.
        if page.isOfAConfiguration, let configuration = session.configuration, several || page != .layouts {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(page == .scenes ? "Scenes of" : page == .share ? "Share" : "Layouts for").font(.title2.weight(.semibold))
                if several {
                    // A menu as wide as the name it shows: a pop-up button is as wide as its longest
                    // item, which a configuration's name can make very long.
                    Menu {
                        ForEach(Array(session.config.configurations.enumerated()), id: \.element.id) { index, each in
                            Button {
                                // A file being placed was read for the other configuration's displays.
                                session.pendingImport = nil
                                session.select(configuration: index)
                            } label: {
                                let name = each.name.isEmpty ? "Untitled" : each.name
                                if index == session.selection.configuration {
                                    Label(name, systemImage: "checkmark")
                                } else {
                                    Text(name)
                                }
                            }
                        }
                    } label: {
                        Text(configuration.name.isEmpty ? "Untitled" : configuration.name).font(.title2.weight(.semibold))
                    }
                    .menuStyle(.borderlessButton).fixedSize()
                    .help(page == .scenes ? "Show the scenes of another configuration"
                          : page == .share ? "Show the sharing of another configuration" : "Put layouts on the desktops of another configuration")
                    .accessibilityLabel("Configuration: \(configuration.name)")
                } else {
                    Text(configuration.name.isEmpty ? "Untitled" : configuration.name).font(.title2.weight(.semibold))
                        .lineLimit(1).truncationMode(.middle)
                }
            }
        } else {
            Text(page.title).font(.title2.weight(.semibold))
        }
    }
}

/// A section of a page: its name, and its settings on a card. Not folded: on a page of a few rows a
/// fold with nothing beside it only hides the setting. The long list of shortcuts alone folds
/// (`FoldSection`).
struct PageSection<Content: View>: View {
    let title: String
    let badge: String?
    let content: Content

    init(_ title: String, badge: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.content = content()
    }

    init(_ section: SettingSection, badge: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(section.title, badge: badge, content: content)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                // As large as the rows it heads and in their colour: smaller and fainter, a
                // section's name read as a caption.
                Text(title).font(.system(size: 13, weight: .semibold)).accessibilityAddTraits(.isHeader)
                if let badge {
                    Text(badge).font(.caption).foregroundColor(.secondary)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.08)))
                }
            }
            VStack(alignment: .leading, spacing: 10) { content }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
        }
    }
}

/// A section of a page that folds: its header shows a badge, so a folded section still says what it
/// holds. Whether it is open is the owner's taste, kept outside the config file.
struct FoldSection<Content: View>: View {
    let title: String
    let badge: String?
    let content: Content
    @AppStorage private var open: Bool

    init(_ title: String, key: String, badge: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.badge = badge
        self.content = content()
        _open = AppStorage(wrappedValue: true, "fold.\(key)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button {
                withAnimation(.easeOut(duration: 0.15)) { open.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundColor(.secondary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title).font(.system(size: 13, weight: .semibold))
                    if let badge {
                        Text(badge).font(.caption).foregroundColor(.secondary)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(open ? "open" : "folded")")
            if open {
                VStack(alignment: .leading, spacing: 10) { content }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
            }
        }
    }
}

/// A command of a page: what it does, a button named by its verb, and for a few seconds what it did.
struct CommandRow: View {
    let title: String
    /// Under the title; empty when the title says it all.
    let detail: String
    let verb: String
    var done = "Done"
    /// The command's name for VoiceOver, when the title is a description of what one gets.
    var name: String?
    let action: () -> Void
    @State private var ranAt: Date?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).fixedSize(horizontal: false, vertical: true)
                if !detail.isEmpty { HelpText(detail) }
            }
            Spacer(minLength: 4)
            if ranAt != nil {
                Label(done, systemImage: "checkmark").font(.caption.weight(.semibold)).foregroundColor(.green)
                    .transition(.opacity)
            }
            Button(verb) {
                action()
                let at = Date()
                withAnimation { ranAt = at }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    if ranAt == at { withAnimation { ranAt = nil } }
                }
            }
            .accessibilityLabel(name ?? title)
        }
    }
}

/// In the header of the Scenes page: what a scene is and does, for who wants it. It was two
/// paragraphs above the first scene, read once and scrolled past ever after.
struct HowScenesWork: View {
    /// The shortcut of the first scene, as the owner set it.
    let first: String
    @State private var shown = false

    var body: some View {
        Button { shown.toggle() } label: {
            Label("How scenes work", systemImage: "questionmark.circle")
        }
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                Text("A scene switches every display it names at once. The palette lists scenes by name, the first four have a shortcut (\(first) for the first), and fremspace://scene/<name> shows one from another tool.")
                Text("It can also put a slot in Focus, open or close a drawer and open apps that are not running.")
                Text("Asking for a scene again while it is shown leaves it: the displays go back to the desktops they showed, and the Focus it gave and the drawers it moved to what they were.")
            }
            .font(.callout).fixedSize(horizontal: false, vertical: true)
            .frame(width: 360, alignment: .leading).padding(16)
        }
    }
}

/// A page about a configuration when there is none: why it is empty, and the way out.
struct NoConfiguration: View {
    @ObservedObject var session: EditSession
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).foregroundColor(.secondary)
            Button("New from connected displays") {
                session.newConfigurationFromConnectedDisplays()
                // Where the new configuration is, with its displays and its first desktop.
                session.settingsPage = nil
            }
            .disabled(session.loadError != nil)
        }
    }
}

/// Every command's shortcut, changed by clicking it and typing the new one. Saved with Save.
struct ShortcutsEditor: View {
    @ObservedObject var session: EditSession
    let actions: SettingsActions
    /// What the owner typed to find a command.
    var filter = ""
    /// The command whose shortcut is being typed.
    @State private var recording: String?
    @State private var monitor: Any?
    /// What is wrong with the shortcut just typed, or what to know about it, under its row.
    @State private var problem: (id: String, text: String)?

    var body: some View {
        let effective = ShortcutCatalog.effective(session.config.shortcuts)
        let shown = ShortcutCatalog.entries.filter { matchesFilter($0, effective[$0.id]) }
        VStack(alignment: .leading, spacing: 18) {
            if filter.isEmpty {
                PageSection(.shortcutsHyper, badge: session.config.hyperKey ? "On" : nil) {
                    SwitchRow(title: SettingRow.hyperKey.title,
                              detail: "Hold Caps Lock instead of the three keys: ⌃⌥⌘Space becomes Caps Lock + Space, here and in every app. Caps Lock no longer locks capitals while this is on.",
                              isOn: Binding(
                                get: { session.config.hyperKey },
                                set: { on in
                                    session.checkpoint()
                                    session.config.hyperKey = on
                                }))
                        .modifier(Revealable(session: session, row: .hyperKey))
                }
            }
            ForEach(ShortcutCatalog.groups.filter { group in shown.contains { $0.group == group } }, id: \.self) { group in
                let changed = ShortcutCatalog.entries.filter { $0.group == group && session.config.shortcuts[$0.id] != nil }.count
                FoldSection(group, key: "shortcuts.\(group)", badge: changed == 0 ? nil : "\(changed) custom") {
                    ForEach(shown.filter { $0.group == group }, id: \.id) { entry in
                        row(entry, effective[entry.id] ?? Shortcut(keyCode: nil))
                    }
                }
            }
            if shown.isEmpty {
                Text("No command matches \u{201C}\(filter)\u{201D}.").foregroundColor(.secondary)
            }
            if !session.config.shortcuts.isEmpty {
                Button("Reset every shortcut") {
                    session.checkpoint()
                    session.config.shortcuts = [:]
                    problem = nil
                }
            }
        }
        .onDisappear { stopRecording() }
        // While a shortcut is being typed every hot key is off: that must end when the owner leaves
        // for another window or another app, not only when a key is typed here.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in stopRecording() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in stopRecording() }
    }

    /// Every word typed is in the command's name or its shortcut, whatever the case and the accents.
    private func matchesFilter(_ entry: ShortcutCatalog.Entry, _ shortcut: Shortcut?) -> Bool {
        let text = (entry.title + " " + entry.group + " " + (shortcut.map(ShortcutCatalog.label) ?? ""))
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        return filter.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(separator: " ").allSatisfy { text.contains($0) }
    }

    private func row(_ entry: ShortcutCatalog.Entry, _ shortcut: Shortcut) -> some View {
        let isRecording = recording == entry.id
        let changed = session.config.shortcuts[entry.id] != nil
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(entry.title)
                Spacer(minLength: 4)
                if changed {
                    Button {
                        reset(entry)
                    } label: {
                        // Not the arrow of Undo, which is in the bar at the foot of the same window.
                        Image(systemName: "arrow.counterclockwise").hitTarget()
                    }
                    .buttonStyle(.borderless)
                    .help(entry.fallback == nil ? "Back to no shortcut" : "Back to \(ShortcutCatalog.label(entry.defaultShortcut))")
                    .accessibilityLabel("Reset the shortcut of \(entry.title)")
                }
                Button {
                    isRecording ? stopRecording() : startRecording(entry.id)
                } label: {
                    recorder(shortcut, recording: isRecording)
                }
                .buttonStyle(.plain)
                .help(isRecording ? "Type the new shortcut; ⌫ for none, ⎋ to keep this one" : "Click, then type the new shortcut")
                .accessibilityLabel("Shortcut of \(entry.title): \(ShortcutCatalog.label(shortcut))")
                .accessibilityAddTraits(isRecording ? .isSelected : [])
            }
            if let problem, problem.id == entry.id {
                Label(problem.text, systemImage: Status.Kind.warning.symbol)
                    .labelStyle(StatusLabelStyle(color: .orange)).font(.callout)
            }
        }
    }

    /// A shortcut as the keys it is made of, in a well: something to type into, not one more button
    /// in a column of buttons. It says so while it listens.
    private func recorder(_ shortcut: Shortcut, recording: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6)
        return HStack(spacing: 3) {
            if recording {
                Text("Type shortcut\u{2026}").font(.callout).foregroundColor(.accentColor)
            } else if shortcut.keyCode == nil {
                Text("None").font(.callout).foregroundColor(.secondary)
            } else {
                ForEach(Array(keys(ShortcutCatalog.label(shortcut)).enumerated()), id: \.offset) { _, key in
                    // The system font: the modifier symbols run together in the monospaced one.
                    Text(key).font(.system(size: 12, weight: .medium))
                        .frame(minWidth: 12).padding(.horizontal, 4).frame(height: 19)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.primary.opacity(0.1)))
                }
            }
        }
        .frame(width: 150, height: 26)
        .background(shape.fill(recording ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
        .overlay(shape.strokeBorder(recording ? Color.accentColor : Color.primary.opacity(0.16), lineWidth: recording ? 1.5 : 1))
        .contentShape(Rectangle())
    }

    /// The keys of a shortcut written as a label ("⌃⌥⌘Space"): each modifier, then the key.
    private func keys(_ label: String) -> [String] {
        let modifiers = label.prefix { "⇪⌃⌥⇧⌘".contains($0) }
        return modifiers.map(String.init) + [String(label.dropFirst(modifiers.count))]
    }

    /// Back to the default, unless another command took it meanwhile: two commands on one shortcut
    /// would leave one of them dead.
    private func reset(_ entry: ShortcutCatalog.Entry) {
        var without = session.config.shortcuts
        without[entry.id] = nil
        if let other = shortcutConflict(entry.defaultShortcut, for: entry.id, effective: ShortcutCatalog.effective(without)),
           let title = ShortcutCatalog.entries.first(where: { $0.id == other })?.title {
            problem = (entry.id, "\(ShortcutCatalog.label(entry.defaultShortcut)) is now \u{201C}\(title)\u{201D}. Change that one first.")
            return NSSound.beep()
        }
        session.checkpoint()
        session.config.shortcuts[entry.id] = nil
        problem = nil
    }

    private func startRecording(_ id: String) {
        stopRecording()
        recording = id
        problem = nil
        // The global hotkeys would run their command instead of being typed here.
        actions.suspendHotkeys(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            typed(event, for: id)
            return nil
        }
    }

    private func stopRecording() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard recording != nil else { return }
        recording = nil
        actions.suspendHotkeys(false)
    }

    private func typed(_ event: NSEvent, for id: String) {
        let plain = event.modifierFlags.intersection([.control, .option, .command, .shift]).isEmpty
        if plain, event.keyCode == 53 { return stopRecording() }
        var shortcut = ShortcutCatalog.shortcut(from: event)
        if plain, event.keyCode == 51 { shortcut = Shortcut(keyCode: nil) }
        guard shortcut.isUsable else {
            problem = (id, "A shortcut needs ⌃, ⌥ or ⌘: a key alone would fire while you type.")
            return NSSound.beep()
        }
        let effective = ShortcutCatalog.effective(session.config.shortcuts)
        if let other = shortcutConflict(shortcut, for: id, effective: effective),
           let title = ShortcutCatalog.entries.first(where: { $0.id == other })?.title {
            problem = (id, "\(ShortcutCatalog.label(shortcut)) is already \u{201C}\(title)\u{201D}. Change that one first.")
            return NSSound.beep()
        }
        session.checkpoint()
        let fallback = ShortcutCatalog.entries.first { $0.id == id }?.defaultShortcut
        // Typing the default again is the same as resetting.
        session.config.shortcuts[id] = shortcut == fallback ? nil : shortcut
        // Taken, with a word about what it costs: ⌘W typed to close this window lands here too.
        problem = shortcut.isAnAppsOwn
            ? (id, "\(ShortcutCatalog.label(shortcut)) is a shortcut apps use themselves: once saved, Fremspace takes it from every app.")
            : nil
        stopRecording()
    }
}

/// One choice of a scene's line: a pop-up button, every one as wide as the others. A SwiftUI picker
/// is as wide as its longest item whatever frame it is given, which left the right edges of a scene's
/// lines ragged; this one is AppKit's, at the width it is told. A line the scene leaves as it is
/// (the option tagged -1) steps back, so that what the scene does stands out.
struct Choice: View {
    let options: [(title: String, tag: Int)]
    let selection: Int
    /// What the choice is about, for VoiceOver: it has no visible label of its own.
    let name: String
    var width: CGFloat = 220
    let choose: (Int) -> Void

    var body: some View {
        PopUp(options: options, selection: selection, name: name, choose: choose)
            .frame(width: width, height: 22)
            .opacity(selection == -1 ? 0.55 : 1)
    }

    private struct PopUp: NSViewRepresentable {
        let options: [(title: String, tag: Int)]
        let selection: Int
        let name: String
        let choose: (Int) -> Void

        func makeCoordinator() -> Coordinator { Coordinator(choose) }

        func makeNSView(context: Context) -> NSPopUpButton {
            let button = NSPopUpButton(frame: .zero, pullsDown: false)
            button.target = context.coordinator
            button.action = #selector(Coordinator.chosen(_:))
            button.setContentHuggingPriority(.defaultLow, for: .horizontal)
            button.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            return button
        }

        func updateNSView(_ button: NSPopUpButton, context: Context) {
            context.coordinator.choose = choose
            if button.itemArray.map(\.title) != options.map(\.title) || button.itemArray.map(\.tag) != options.map(\.tag) {
                button.removeAllItems()
                for option in options {
                    // Not addItem(withTitle:), which drops an item named like an earlier one.
                    let item = NSMenuItem(title: option.title, action: nil, keyEquivalent: "")
                    item.tag = option.tag
                    button.menu?.addItem(item)
                }
            }
            button.selectItem(withTag: selection)
            button.setAccessibilityLabel(name)
        }

        final class Coordinator: NSObject {
            var choose: (Int) -> Void

            init(_ choose: @escaping (Int) -> Void) { self.choose = choose }

            @objc func chosen(_ sender: NSPopUpButton) { choose(sender.selectedTag()) }
        }
    }
}

/// The scenes of the selected configuration: a name, for each display the desktop it shows, the
/// slot it puts in Focus there and what it does with the display's drawers, and the apps it opens.
struct ScenesEditor: View {
    @ObservedObject var session: EditSession

    /// The apps the configurations already place somewhere: offered even when they are not running.
    private var configuredApps: [String] {
        session.config.configurations.flatMap(\.displays).flatMap(\.spaces)
            .flatMap { $0.layout?.slots ?? [] }.flatMap(\.rules).map(\.bundleID)
    }

    /// A slot as the owner knows it: its apps.
    private func slotName(_ slot: Slot) -> String {
        slot.rules.map { appName($0.bundleID) + ($0.profile.map { " \u{2013} \($0)" } ?? "") }.joined(separator: ", ")
    }


    /// One line of a display: what it is about, then the choice.
    private func line<Content: View>(_ title: String, detail: Bool = false, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(title).lineLimit(1).truncationMode(.middle)
                .foregroundColor(detail ? .secondary : .primary)
                .padding(.leading, detail ? 14 : 0)
                .frame(width: 200, alignment: .leading)
            content()
        }
    }

    var body: some View {
        if let configuration = session.configuration {
            let displays = configuration.displays.filter { !$0.ignored }
            VStack(alignment: .leading, spacing: 18) {
                ForEach(Array(configuration.scenes.enumerated()), id: \.element.id) { index, scene in
                    VStack(alignment: .leading, spacing: 8) {
                        // Which scene this is and its shortcut, over its name: a bare field at the top
                        // of a card did not say what it named.
                        HStack(spacing: 8) {
                            Text("Scene \(index + 1)").font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
                            if index < 4 {
                                Text(session.shortcutLabel("scene.\(index + 1)")).font(.subheadline).foregroundColor(.secondary)
                            }
                            Spacer(minLength: 4)
                            Button {
                                session.removeScene(scene.id)
                            } label: {
                                Image(systemName: "trash").hitTarget()
                            }
                            .buttonStyle(.borderless)
                            .help("Delete this scene (Undo brings it back)")
                            .accessibilityLabel("Delete the scene \(scene.name)")
                        }
                        TextField("Name", text: Binding(
                            get: { scene.name },
                            set: { name in session.updateScene(scene.id) { $0.name = name } }))
                            .textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                            .accessibilityLabel("Name of scene \(index + 1)")
                        ForEach(displays, id: \.identity) { display in
                            line(display.displayName) {
                                Choice(options: [("No change", -1)] + display.spaces.enumerated().map { ("\($0.offset + 1). \($0.element.label)", $0.offset) },
                                       selection: scene.desktop(on: display.identity) ?? -1,
                                       name: "Desktop of \(display.displayName) in the scene \(scene.name)") { choice in
                                    session.updateScene(scene.id) { $0.set(choice < 0 ? nil : choice, on: display.identity) }
                                }
                            }
                            // Focus is of a slot: only on a desktop the scene names, among the slots Focus enlarges.
                            if let index = scene.desktop(on: display.identity), display.spaces.indices.contains(index),
                               case let slots = focusSlots(display.spaces[index]), !slots.isEmpty {
                                line("Focus", detail: true) {
                                    // Position 0 is "No change"; the slots follow in their order.
                                    let chosen = scene.focus(on: display.identity).flatMap { id in slots.firstIndex { $0.id == id } }
                                    Choice(options: [("No change", -1)] + slots.enumerated().map { (slotName($0.element), $0.offset) },
                                           selection: chosen ?? -1,
                                           name: "Slot in Focus on \(display.displayName) in the scene \(scene.name)") { choice in
                                        session.updateScene(scene.id) { $0.setFocus(slots.indices.contains(choice) ? slots[choice].id : nil, on: display.identity) }
                                    }
                                }
                            }
                            ForEach(display.drawers, id: \.edge) { drawer in
                                line(drawer.edge == .left ? "Left drawer" : "Right drawer", detail: true) {
                                    Choice(options: [("No change", -1), ("Open", 1), ("Closed", 0)],
                                           selection: scene.drawer(drawer.edge, on: display.identity).map { $0 ? 1 : 0 } ?? -1,
                                           name: "\(drawer.edge == .left ? "Left" : "Right") drawer of \(display.displayName) in the scene \(scene.name)") { choice in
                                        session.updateScene(scene.id) { $0.setDrawer(choice < 0 ? nil : choice == 1, edge: drawer.edge, on: display.identity) }
                                    }
                                }
                            }
                        }
                        line("Opens") {
                            ForEach(scene.apps, id: \.self) { bundleID in
                                HStack(spacing: 4) {
                                    if let icon = AppIcons.small(bundleID) { Image(nsImage: icon) }
                                    Text(appName(bundleID)).lineLimit(1)
                                    Button {
                                        session.updateScene(scene.id) { $0.apps.removeAll { $0 == bundleID } }
                                    } label: {
                                        Image(systemName: "xmark.circle.fill").foregroundColor(.secondary).hitTarget(18)
                                    }
                                    .buttonStyle(.borderless)
                                    .accessibilityLabel("Do not open \(appName(bundleID)) with the scene \(scene.name)")
                                }
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(Capsule().fill(Color.primary.opacity(0.08)))
                            }
                            AppMenu(title: "Add an app\u{2026}", bundleID: nil, known: configuredApps) { id in
                                guard !scene.apps.contains(id) else { return }
                                session.updateScene(scene.id) { $0.apps.append(id) }
                            }
                            .fixedSize()
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                }
                if configuration.scenes.isEmpty {
                    Text("No scene yet.").foregroundColor(.secondary)
                }
                HStack(spacing: 8) {
                    Button("Add a scene from what the displays show now") { session.addScene(capturing: true) }
                        .disabled(!session.isActive(configuration))
                    Button("Add an empty scene") { session.addScene(capturing: false) }
                }
                // The page's main button, off: the reason is written, not left to a tooltip.
                if !session.isActive(configuration) {
                    HelpText("\u{201C}\(configuration.name)\u{201D} is not the configuration in use: there is nothing on the displays to start a scene from.")
                }
            }
        } else {
            NoConfiguration(session: session, text: "Scenes belong to a configuration: make one first.")
        }
    }
}

/// The configuration selected as a file for somebody else. The export is shown before it is written:
/// what is in the file, what never is, and the free text that goes in only when the owner says so.
/// Files from others, and the ones kept, are on the Layouts page.
struct ShareEditor: View {
    @ObservedObject var session: EditSession

    private func row<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).foregroundColor(.secondary).frame(width: 130, alignment: .leading)
            content()
        }
    }

    private func count(_ number: Int, _ one: String) -> String {
        "\(number) \(one)\(number == 1 ? "" : "s")"
    }

    /// "3 displays, 8 desktops": what there is none of is not listed ("0 scenes" said nothing).
    private func counts(_ pairs: [(Int, String)]) -> String {
        pairs.filter { $0.0 > 0 }.map { count($0.0, $0.1) }.joined(separator: ", ")
    }

    var body: some View {
        if let configuration = session.configuration, let export = session.shareExport {
            let report = export.report
            PageSection("Export") {
                HelpText("\u{201C}\(configuration.name)\u{201D} as it is in the editor, in one file to post or to send. Whoever loads it adds your desktops beside theirs.")
                row("In the file") {
                    Text(counts([(report.displays, "display"), (report.desktops, "desktop"), (report.slots, "slot"),
                                 (report.drawers, "drawer"), (report.scenes, "scene")]))
                }
                row("Apps") {
                    Text(report.apps.isEmpty ? "None" : report.apps.map(appName).joined(separator: ", "))
                        .fixedSize(horizontal: false, vertical: true)
                }
                row("Of your displays") {
                    Text("The shape of each one that is connected (how wide for how high), so that a layout made for a tall display is not a surprise on a wide one.")
                        .fixedSize(horizontal: false, vertical: true)
                }
                row("Never in it") {
                    Text("The models and serial numbers of your displays (a display is its name, or \u{201C}Display 2\u{201D}), your shortcuts and general settings, and what Fremspace remembers about your windows."
                         + (report.displaysIgnored > 0 ? " \(count(report.displaysIgnored, "ignored display")) left out." : ""))
                        .fixedSize(horizontal: false, vertical: true)
                }
                let filters = session.shareFilters
                if !filters.profiles.isEmpty || !filters.titles.isEmpty {
                    Toggle("Include browser profiles and window title filters", isOn: $session.shareWithFilters)
                    HelpText((session.shareWithFilters ? "In the file as you typed them: " : "Left out, because they are free text that can name an employer or a customer: ")
                             + (filters.profiles.map { "profile \u{201C}\($0)\u{201D}" } + filters.titles.map { "title \u{201C}\($0)\u{201D}" }).joined(separator: ", ") + ".")
                }
                HStack(spacing: 8) {
                    // The page's main action; the two others are other ways to the same file.
                    Button("Export\u{2026}") { session.exportLayout() }
                        .buttonStyle(.borderedProminent)
                    Button("Copy") { session.copyLayout() }
                        .help("The same text on the clipboard")
                    Button("Keep in Layouts") { session.keepInLibrary() }
                        .help("A copy among the whole desks of the Layouts page, to add to another configuration later")
                }
            }
            PageSection("From somebody else") {
                HelpText("A layout file you were sent is opened on the Layouts page, where you see what it holds before anything is added.")
                Button("Show the Layouts page") {
                    session.layoutsView = .wholeDesks
                    session.settingsPage = .layouts
                }
            }
        } else {
            NoConfiguration(session: session, text: "Sharing is of a configuration: make one first.")
        }
    }
}
