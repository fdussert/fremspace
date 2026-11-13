import AppKit
import Combine
import FremspaceCore
import SwiftUI

/// What the settings pages can do besides editing the file: the status menu's commands.
struct SettingsActions {
    var reapply: () -> Void = {}
    var restoreEverything: () -> Void = {}
    var bringBack: () -> Void = {}
    var copyDiagnostics: () -> Void = {}
    var dumpWindows: () -> Void = {}
    var openConfigFile: () -> Void = {}
    var reloadConfig: () -> Void = {}
    /// True while a shortcut is being typed: the global hotkeys must not fire.
    var suspendHotkeys: (Bool) -> Void = { _ in }
    /// The shortcuts another app holds, for the Status page.
    var takenShortcuts: () -> [String] = { [] }
}

/// The settings and layout editor window (one, reused). Closing it with unsaved changes asks first.
final class SettingsWindow: NSObject, NSWindowDelegate {
    var actions = SettingsActions()
    /// Read by the menu bar's commands (`MainMenu`), which act on what the window edits.
    private(set) var window: NSWindow?
    private(set) var session: EditSession?
    private var dirtyWatch: AnyCancellable?
    private let store: ConfigStore
    private let engine: Engine
    private let windows: AXWindows

    init(store: ConfigStore, engine: Engine, windows: AXWindows) {
        self.store = store
        self.engine = engine
        self.windows = windows
    }

    func show() {
        if window == nil {
            let session = EditSession(store: store, engine: engine, windows: windows)
            session.takenShortcuts = actions.takenShortcuts
            session.refreshAttention()
            // Something stops Fremspace: the window opens on what it is.
            if session.attention.contains(where: { $0.level == .blocking }) { session.settingsPage = .status }
            // Wide enough for the drawing of a display to be the main thing in the window (it has
            // what the sidebar and the inspector leave), and never larger than the screen it opens on.
            let screen = NSScreen.main?.visibleFrame.size ?? NSSize(width: 1440, height: 900)
            let size = NSSize(width: min(1320, screen.width - 80), height: min(860, screen.height - 80))
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                  styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
            window.contentView = NSHostingView(rootView: SettingsView(session: session, actions: actions))
            window.delegate = self
            window.isReleasedWhenClosed = false
            window.setFrameAutosaveName("FremspaceSettings")
            if !window.setFrameUsingName("FremspaceSettings") { window.center() }
            dirtyWatch = session.objectWillChange.receive(on: DispatchQueue.main).sink { [weak self] _ in
                self?.reflectSession()
            }
            self.window = window
            self.session = session
            reflectSession()
        }
        // A menu bar app is not in ⌘Tab nor in the Dock: while its window is open Fremspace is a
        // regular app, so the owner can come back to it like to any window (owner, 2026-11-10).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// What the title bar says about the session: what is shown, as the window's name (in the Window
    /// menu and in Mission Control "Fremspace" told one window from no other), and whether it is
    /// saved, with the dot in the close button, like a document.
    private func reflectSession() {
        guard let window, let session else { return }
        let configuration = session.configuration.map { $0.name.isEmpty ? "Untitled" : $0.name }
        window.title = session.settingsPage?.title ?? configuration ?? "Fremspace"
        window.subtitle = session.isDirty ? "Edited" : ""
        window.isDocumentEdited = session.isDirty
        let editing = session.settingsPage == nil && session.displaySpec?.ignored == false
        MainMenu.reflect(desktops: editing ? session.displaySpec?.spaces.map(\.label) ?? [] : [],
                         selected: session.selection.desktop, updates: session.engine.updates.isAvailable)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        // Displays and desktops may have changed while the owner was elsewhere (Mission Control).
        session?.refreshEnvironment()
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        settleUnsavedChanges()
    }

    /// Before the app quits (⌘Q while the editor is in front, the menu's Quit, a logout, an update's
    /// relaunch): the same question as when the window closes. False: do not quit.
    func mayQuit() -> Bool {
        guard let session, session.isDirty else { return true }
        // The question is about this window: it comes to the front with it.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
        return settleUnsavedChanges()
    }

    /// Asks what becomes of the unsaved changes, wherever they are about to be lost. True: go on
    /// (saved, or given up); false: stay (cancelled, or the save was refused and says why).
    private func settleUnsavedChanges() -> Bool {
        guard let session, session.isDirty else { return true }
        let alert = NSAlert()
        // Not "to your layouts": a shortcut or a setting may be all that changed.
        alert.messageText = "Save your changes?"
        alert.informativeText = "Nothing changes on screen until they are saved."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Discard").hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            session.save()
            return !session.isDirty
        case .alertSecondButtonReturn:
            session.revert()
            return true
        default:
            return false
        }
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        // A fresh session next time, read from the file.
        dirtyWatch = nil
        window = nil
        session = nil
    }
}

struct SettingsView: View {
    @ObservedObject var session: EditSession
    let actions: SettingsActions

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Sidebar(session: session)
                    .frame(width: 210)
                Divider()
                if let page = session.settingsPage {
                    SettingsPageView(session: session, page: page, actions: actions)
                        .id(page)
                } else if session.configuration != nil {
                    EditorArea(session: session)
                } else {
                    EmptyEditor(session: session)
                }
            }
            Divider()
            StatusBar(session: session)
        }
        // Under this the tiles of the screen drawing have no room for their names.
        .frame(minWidth: 1100, minHeight: 660)
    }
}

/// Shown when the file holds no configuration yet: the first thing a new owner sees. It names the
/// displays found, says the three steps, and has one button.
struct EmptyEditor: View {
    @ObservedObject var session: EditSession

    var body: some View {
        VStack(spacing: 18) {
            if let loadError = session.loadError {
                Banner(kind: .error, text: "\(loadError) Nothing can be set up until the file is readable: see the Status page.")
                    .frame(maxWidth: 460)
            }
            VStack(spacing: 6) {
                Image(systemName: "rectangle.3.group").font(.system(size: 34, weight: .light)).foregroundColor(.secondary)
                Text("Set up your displays").font(.title2.weight(.semibold))
                Text("A configuration holds the layouts for one set of displays: your desk, the laptop alone, another office.")
                    .foregroundColor(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !session.connected.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(session.connected, id: \.identity) { display in
                        HStack(spacing: 8) {
                            Image(systemName: display.identity.name.localizedCaseInsensitiveContains("built-in") ? "laptopcomputer" : "display")
                                .foregroundColor(.secondary).frame(width: 22)
                            Text(display.identity.name).lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 12)
                            Text(counted(session.desktopCounts[display.identity] ?? 1, "desktop")).foregroundColor(.secondary)
                        }
                    }
                }
                .padding(12)
                .frame(width: 360)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Displays found")
            }
            VStack(alignment: .leading, spacing: 5) {
                step(1, "Give each desktop a layout: capture the windows it shows, or split it into slots.")
                step(2, "Choose the app of each slot.")
                step(3, "Save. Nothing changes on screen before.")
            }
            .frame(width: 360, alignment: .leading)
            Button(session.connected.isEmpty ? "New configuration" : "Set up these displays") {
                session.newConfigurationFromConnectedDisplays()
            }
            .controlSize(.large).buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            .disabled(session.loadError != nil)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)").font(.subheadline.weight(.semibold).monospacedDigit()).foregroundColor(.secondary)
                .frame(width: 22, alignment: .center)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The window's destinations, always in view (after Fremkit's settings): the configurations, whose
/// layouts the editor shows, then Fremspace's own settings pages.
struct Sidebar: View {
    @ObservedObject var session: EditSession
    @State private var renaming: UUID?
    @SwiftUI.FocusState private var nameFocused: Bool
    /// The search result ↑ ↓ are on.
    @State private var chosen = 0
    @State private var searchFocus = SearchFocus()

    var body: some View {
        let hits = session.searchHits
        VStack(spacing: 0) {
            SidebarSearchField(text: $session.search, focus: searchFocus,
                               onMove: { step in chosen = max(0, min(hits.count - 1, chosen + step)) },
                               onSubmit: { if hits.indices.contains(chosen) { session.open(hits[chosen]) } })
                .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 4)
                .onChange(of: session.search) { _ in chosen = 0 }
                // Find, from the Edit menu.
                .onChange(of: session.searchRequests) { _ in searchFocus.take() }
                .background(
                    // ⌘F from anywhere in the window.
                    Button("Search") { searchFocus.take() }
                        .keyboardShortcut("f", modifiers: .command).opacity(0).accessibilityHidden(true))
            ScrollView {
                if session.search.trimmingCharacters(in: .whitespaces).isEmpty {
                    lists
                } else {
                    SearchResults(session: session, hits: hits, selected: chosen)
                        .padding(.horizontal, 8).padding(.top, 6).padding(.bottom, 8)
                }
            }
            // Always in view: which version this is, the first thing asked in a report.
            Text("Fremspace \(AppVersion.current)")
                .font(.caption).foregroundColor(.secondary).textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(Color.primary.opacity(0.035))
    }

    private var lists: some View {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 2) {
                    groupLabel("Configurations")
                    Spacer(minLength: 0)
                    Menu {
                        Button("New from connected displays") { session.newConfigurationFromConnectedDisplays() }
                        Button("Duplicate \u{201C}\(session.configuration?.name ?? "")\u{201D}") { session.duplicateConfiguration() }
                            .disabled(session.configuration == nil)
                        // For the laptop on the move: one display, each slot of the others as a desktop.
                        let displays = session.configuration?.displays.filter { !$0.ignored } ?? []
                        if displays.count > 1 {
                            Divider()
                            ForEach(displays, id: \.identity) { display in
                                Button("Travel version, \(display.displayName) only") {
                                    session.addTravelConfiguration(keeping: display.identity)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 24)
                    .help("Add a configuration")
                    .accessibilityLabel("Add a configuration")
                    // What can be done with the selected configuration, behind a menu: a bare minus
                    // beside the plus deleted every layout of a set of displays on one click, and
                    // renaming was a double-click nobody is told about.
                    Menu {
                        let index = session.selection.configuration
                        if let configuration = session.configuration {
                            Button("Rename") { beginRenaming(index, configuration) }
                            Button("Duplicate") { session.duplicateConfiguration() }
                            Divider()
                            Button("Delete \u{201C}\(configuration.name)\u{201D}") { session.deleteConfiguration(at: index) }
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 24, height: 24)
                    .disabled(session.configuration == nil)
                    .help(session.configuration == nil ? "No configuration yet" : "Rename, duplicate or delete the selected configuration")
                    .accessibilityLabel("Actions on the selected configuration")
                }
                .padding(.trailing, 4)
                ForEach(Array(session.config.configurations.enumerated()), id: \.element.id) { i, configuration in
                    row(i, configuration)
                }
                if session.config.configurations.isEmpty {
                    Text("None yet").font(.callout).foregroundColor(.secondary).padding(.horizontal, 8).padding(.vertical, 4)
                }
                // Not the app's name: it is already the window's title.
                groupLabel("Settings").padding(.top, 14)
                ForEach(SettingsPage.allCases) { page in pageRow(page) }
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 8)
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title).font(.subheadline.weight(.semibold)).foregroundColor(.secondary)
            .padding(.horizontal, 8).padding(.bottom, 4)
            .accessibilityAddTraits(.isHeader)
    }

    /// On a row that holds unsaved changes: the bar at the bottom says there are some, this says where.
    private func unsavedDot(selected: Bool) -> some View {
        Circle().fill(selected ? Color.white : Color.accentColor).frame(width: 6, height: 6)
            .help("Unsaved changes")
            .accessibilityLabel("Unsaved changes")
    }

    private func pageRow(_ page: SettingsPage) -> some View {
        let selected = session.settingsPage == page
        let badge = page.badge(session)
        let unsaved = session.unsaved
        let changed = page == .general ? unsaved.general : page == .shortcuts ? unsaved.shortcuts : page == .scenes ? unsaved.scenes : false
        return Button {
            session.settingsPage = page
        } label: {
            HStack(spacing: 8) {
                Image(systemName: page.symbol).frame(width: 18)
                Text(page.title)
                Spacer(minLength: 0)
                if let badge, page == .status {
                    // A count of what needs the owner, red when something stops Fremspace.
                    let blocking = session.attention.contains { $0.level == .blocking }
                    Text(badge).font(.caption.weight(.semibold)).foregroundColor(.white)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(blocking ? Color.red : Color.orange))
                        .accessibilityLabel("\(badge) to look at")
                } else if let badge {
                    Text(badge).font(.caption).foregroundColor(selected ? .white.opacity(0.8) : .secondary)
                }
                if changed { unsavedDot(selected: selected) }
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .foregroundColor(selected ? .white : .primary)
            .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : Color.clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(page.summary)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func row(_ i: Int, _ configuration: Configuration) -> some View {
        let selected = i == session.selection.configuration && session.settingsPage == nil
        // Scenes and Share are about one configuration: it stays marked, quietly, while they are shown.
        let concerned = i == session.selection.configuration && session.settingsPage?.isOfAConfiguration == true
        HStack(spacing: 6) {
            VStack(alignment: .leading, spacing: 1) {
                if renaming == configuration.id {
                    TextField("Name", text: Binding(
                        get: { session.config.configurations.indices.contains(i) ? session.config.configurations[i].name : "" },
                        set: { if session.config.configurations.indices.contains(i) { session.config.configurations[i].name = $0 } }))
                        .textFieldStyle(.plain)
                        .focused($nameFocused)
                        .onSubmit { renaming = nil }
                } else {
                    Text(configuration.name.isEmpty ? "Untitled" : configuration.name).lineLimit(1)
                }
                Text(counted(configuration.displays.count, "display")).font(.caption)
                    .foregroundColor(selected ? .white.opacity(0.75) : .secondary)
            }
            Spacer(minLength: 0)
            if session.isActive(configuration) {
                // The text in its own colour on the green: green on a tint of green could not be
                // read in the light appearance.
                Text("In use").font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(Capsule().fill(selected ? Color.white.opacity(0.22) : Color.green.opacity(0.26)))
                    .foregroundColor(selected ? .white : .primary)
                    .help("Fremspace applies this configuration now")
            }
            if session.unsaved.configurations.contains(configuration.id) { unsavedDot(selected: selected) }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .foregroundColor(selected ? .white : .primary)
        .background(RoundedRectangle(cornerRadius: 6).fill(selected ? Color.accentColor : concerned ? Color.primary.opacity(0.1) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture {
            session.settingsPage = nil
            session.select(configuration: i)
        }
        // Simultaneous, so that selecting does not wait to see whether a second click comes.
        .simultaneousGesture(TapGesture(count: 2).onEnded { beginRenaming(i, configuration) })
        // The whole name when it is cut, and how to change it.
        .help("\(configuration.name.isEmpty ? "Untitled" : configuration.name): double-click to rename")
        // One element, except while its name is being typed: the field must stay reachable.
        .accessibilityElement(children: renaming == configuration.id ? .contain : .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction {
            session.settingsPage = nil
            session.select(configuration: i)
        }
        .contextMenu {
            Button("Rename") { beginRenaming(i, configuration) }
            Button("Duplicate") { session.select(configuration: i); session.duplicateConfiguration() }
            SwiftUI.Divider()
            Button("Delete") { session.deleteConfiguration(at: i) }
        }
        .onChange(of: nameFocused) { focused in
            if !focused && renaming == configuration.id { renaming = nil }
        }
    }

    private func beginRenaming(_ i: Int, _ configuration: Configuration) {
        session.settingsPage = nil
        session.select(configuration: i)
        renaming = configuration.id
        DispatchQueue.main.async { nameFocused = true }
    }
}

/// Displays, desktops, canvas and inspector of the selected configuration.
struct EditorArea: View {
    @ObservedObject var session: EditSession

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                if let loadError = session.loadError {
                    Banner(kind: .error, text: "\(loadError) Saving is off so the file is not overwritten: fix it with \"Open config file\" in the menu, then reopen Settings.")
                }
                DisplayStrip(session: session)
                DesktopTabs(session: session)
                CanvasView(session: session)
                Spacer(minLength: 0)
            }
            .padding(16)
            Divider()
            InspectorView(session: session)
                .frame(width: 280)
        }
    }
}

/// A message that stays above the editor.
struct Banner: View {
    let kind: Status.Kind
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: kind.symbol).foregroundColor(kind.color)
            Text(text).fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(kind.color.opacity(0.12)))
    }
}

extension Status.Kind {
    var symbol: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    var color: Color {
        switch self {
        case .info: return .secondary
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}

/// What is going on (the problem that blocks saving, the last result, or what is unsaved and where),
/// undo and redo, Revert and Save. Tinted while something is unsaved: the window's one rule, that
/// nothing changes on screen before Save, was carried by a seven-point dot.
struct StatusBar: View {
    @ObservedObject var session: EditSession

    var body: some View {
        let problem = session.isDirty ? session.problem : nil
        HStack(spacing: 10) {
            Button { session.undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .keyboardShortcut("z", modifiers: .command)
                .disabled(!session.canUndo)
                .help("Undo (⌘Z)")
                .accessibilityLabel("Undo")
            Button { session.redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .keyboardShortcut("z", modifiers: [.command, .shift])
                .disabled(!session.canRedo)
                .help("Redo (⇧⌘Z)")
                .accessibilityLabel("Redo")
            if let problem {
                // What stops Save is not a note: in the text's own colour.
                Label(problem.text, systemImage: Status.Kind.warning.symbol)
                    .labelStyle(StatusLabelStyle(color: Status.Kind.warning.color, ink: .primary))
                Button("Show") { session.selection = problem.selection }
                    .buttonStyle(.link)
            } else if let status = session.status {
                Label(status.text, systemImage: status.kind.symbol)
                    .labelStyle(StatusLabelStyle(color: status.kind.color))
            } else if session.isDirty {
                let places = unsavedPlaces(session.unsaved, in: session.config)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(places.isEmpty ? "Unsaved changes." : "Unsaved changes in \(listed(places)).")
                    Text("Nothing changes on screen until you save.").foregroundColor(.secondary)
                }
                .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button("Revert") { session.revert() }
                .disabled(!session.isDirty)
                .help("Go back to the saved file (Undo brings your changes back)")
            Button("Save") { session.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(!session.isDirty || problem != nil || session.loadError != nil)
                .help(problem?.text ?? (session.loadError != nil ? "Saving is off: the config file could not be read"
                                        : session.isDirty ? "Save and apply the layouts (⌘S)" : "Nothing to save"))
        }
        .padding(.horizontal, 14).padding(.vertical, 9)
        .background(session.isDirty ? Color.accentColor.opacity(0.1) : Color.primary.opacity(0.035))
    }
}

struct StatusLabelStyle: LabelStyle {
    let color: Color
    var ink = Color.secondary

    func makeBody(configuration: LabelStyleConfiguration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.foregroundColor(color).font(.system(size: 12))
            configuration.title.foregroundColor(ink).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
    }
}
