import AppKit
import FremspaceCore

/// The menu bar item and its menu.
final class StatusMenu: NSObject, NSMenuDelegate {
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let menu = NSMenu()
    private let statusLine = NSMenuItem(title: "", action: nil, keyEquivalent: "")
    private let pauseItem = NSMenuItem(title: "Pause", action: nil, keyEquivalent: "p")
    /// "This desktop is…": ties the desktop shown under the mouse to a configured desktop.
    private let thisDesktopItem = NSMenuItem(title: "This desktop is…", action: nil, keyEquivalent: "")
    private let windows: AXWindows
    private let engine: Engine
    private let store: ConfigStore
    private let settings: SettingsWindow

    init(windows: AXWindows, engine: Engine, store: ConfigStore) {
        self.windows = windows
        self.engine = engine
        self.store = store
        settings = SettingsWindow(store: store, engine: engine, windows: windows)
        super.init()
        statusLine.isEnabled = false
        // Status and warnings; Window; desktops; admin; recovery; quit.
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(windowItem())
        menu.addItem(.separator())
        add("Re-apply layout", #selector(reapply), key: "r")
        pauseItem.action = #selector(togglePause)
        pauseItem.target = self
        pauseItem.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(pauseItem)
        add("Restore everything now", #selector(restoreEverything))
        let thisDesktopMenu = NSMenu()
        thisDesktopMenu.autoenablesItems = false
        thisDesktopItem.submenu = thisDesktopMenu
        menu.addItem(thisDesktopItem)
        menu.addItem(.separator())
        let adminItem = NSMenuItem(title: "Open Fremspace admin", action: #selector(openSettings), keyEquivalent: ",")
        adminItem.keyEquivalentModifierMask = [.control, .option, .command]
        adminItem.target = self
        menu.addItem(adminItem)
        if engine.updates.isAvailable { add("Check for Updates\u{2026}", #selector(checkForUpdates)) }
        menu.addItem(.separator())
        menu.addItem(recoveryItem())
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Fremspace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        // The General page of the admin runs the same commands ("Open at login" lives there).
        settings.actions = SettingsActions(
            reapply: { [weak self] in self?.reapply() },
            restoreEverything: { [weak self] in self?.restoreEverything() },
            bringBack: { [weak self] in self?.bringBack() },
            copyDiagnostics: { [weak self] in self?.copyDiagnostics() },
            dumpWindows: { [weak self] in self?.dumpWindows() },
            openConfigFile: { [weak self] in self?.openConfig() },
            reloadConfig: { [weak self] in self?.reloadConfig() },
            suspendHotkeys: { [weak self] suspended in self?.suspendHotkeys?(suspended) },
            takenShortcuts: { [weak self] in self?.takenShortcuts ?? [] })
        item.menu = menu
        show(engine.status)
    }

    /// Shown in the menu and, when Fremspace is not running a configuration, in the menu bar too:
    /// failures are visible, never silent.
    /// One disabled line per hotkey another app already owns (e.g. Rectangle), under the status line.
    /// "Missing desktops: DELL (1) needs 3, has 2", with "Add them", refreshed when the menu opens.
    private var missingItems: [NSMenuItem] = []

    private func showMissingDesktops() {
        missingItems.forEach { menu.removeItem($0) }
        missingItems = []
        let missing = engine.missingDesktops
        guard !missing.isEmpty else { return }
        let text = missing.map { "\(engine.displayName($0.display)) needs \($0.needed), has \($0.present)" }.joined(separator: "; ")
        let line = NSMenuItem(title: "Missing desktops: \(text)", action: nil, keyEquivalent: "")
        line.isEnabled = false
        let add = NSMenuItem(title: "Add the missing desktops", action: #selector(addDesktops), keyEquivalent: "")
        add.target = self
        menu.insertItem(line, at: 1)
        menu.insertItem(add, at: 2)
        missingItems = [line, add]
    }

    /// Warns while macOS reorders desktops by recent use: Fremspace finds desktops by position.
    private var spacesOrderItem: NSMenuItem?

    private func showSpacesOrder() {
        if let old = spacesOrderItem { menu.removeItem(old) }
        spacesOrderItem = nil
        let raw = CFPreferencesCopyAppValue("mru-spaces" as CFString, "com.apple.dock" as CFString)
        guard let text = SpacesOrder.warning(mruSpaces: raw) else { return }
        let line = NSMenuItem(title: text, action: #selector(openMissionControlSettings), keyEquivalent: "")
        line.target = self
        menu.insertItem(line, at: 1)
        spacesOrderItem = line
    }

    @objc private func openMissionControlSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Desktop-Settings.extension") {
            NSWorkspace.shared.open(url)
        }
    }

    @objc private func addDesktops() {
        if !engine.addMissingDesktops() {
            let alert = NSAlert()
            alert.messageText = "Fremspace could not add the desktops."
            alert.informativeText = "Add them in Mission Control (the + at the top right of each display)."
            alert.runModal()
        }
    }

    private var failedHotkeyItems: [NSMenuItem] = []
    /// Set by the app delegate: lets go of the hotkeys while a shortcut is typed in Settings.
    var suspendHotkeys: ((Bool) -> Void)?

    /// The shortcuts another app holds, as they are written.
    private(set) var takenShortcuts: [String] = []

    func showFailedHotkeys(_ labels: [String]) {
        takenShortcuts = labels
        failedHotkeyItems.forEach { menu.removeItem($0) }
        failedHotkeyItems = []
        for (offset, label) in labels.enumerated() {
            let item = NSMenuItem(title: "Hotkey taken by another app: \(label)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: 1 + offset)
            failedHotkeyItems.append(item)
        }
    }

    private var refusedShortcutItems: [NSMenuItem] = []

    /// The commands whose shortcut in the config file cannot be used (see `Shortcut.isUsable`).
    func showRefusedShortcuts(_ commands: [String]) {
        refusedShortcutItems.forEach { menu.removeItem($0) }
        refusedShortcutItems = []
        for (offset, command) in commands.enumerated() {
            let item = NSMenuItem(title: "Shortcut in the config file not usable: \(command)", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.insertItem(item, at: 1 + offset)
            refusedShortcutItems.append(item)
        }
    }

    func show(_ status: EngineStatus) {
        switch status {
        case .running(let name):
            statusLine.title = "Running: \(name)"
            setIcon(title: "")
        case .free(let reason):
            statusLine.title = "Free: \(reason)"
            setIcon(title: " free")
        case .paused:
            statusLine.title = "Paused"
            setIcon(title: "")
        }
        pauseItem.state = status == .paused ? .on : .off
    }

    /// The glyph changed (another desktop, another slot in front, Focus): drawn again if it differs.
    func show(_ glyph: MenuGlyph) {
        guard glyph != shownGlyph, let button = item.button else { return }
        shownGlyph = glyph
        button.image = MenuBarIcon.image(glyph)
    }

    private var shownGlyph: MenuGlyph?

    /// The menu bar shows the layout of the desktop the owner is on (see MenuBarIcon); "free" stays
    /// written next to it, so that a failure is never silent.
    private func setIcon(title: String) {
        guard let button = item.button else { return }
        shownGlyph = nil
        show(engine.menuGlyph)
        button.imagePosition = .imageLeading
        button.title = title
        button.toolTip = statusLine.title
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        if menu === windowMenu { return buildWindowMenu(windowMenu) }
        if menu === popupMenu { return }
        show(engine.status)
        showMissingDesktops()
        showSpacesOrder()
        showThisDesktop()
        showMoverAvailability()
        showDidNotStart()
    }

    private var didNotStartItem: NSMenuItem?

    /// Apps launched at login that showed no window in time.
    private func showDidNotStart() {
        if let old = didNotStartItem { menu.removeItem(old) }
        didNotStartItem = nil
        let apps = engine.loginRestorer.didNotStart
        guard !apps.isEmpty else { return }
        let names = apps.map { id in
            NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map { $0.deletingPathExtension().lastPathComponent } ?? id
        }
        let line = NSMenuItem(title: "Did not start: \(names.joined(separator: ", "))", action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.insertItem(line, at: 1)
        didNotStartItem = line
    }

    /// "Window": commands on the active window, rebuilt each time it opens.
    private let windowMenu = NSMenu()

    private func windowItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Window", action: nil, keyEquivalent: "")
        windowMenu.delegate = self
        windowMenu.autoenablesItems = false
        item.submenu = windowMenu
        return item
    }

    /// ⌃⌥⌘W: the Window menu under the mouse, for the active window.
    func popUpWindowMenu() {
        let popup = NSMenu()
        popup.autoenablesItems = false
        popup.delegate = self
        buildWindowMenu(popup)
        popupMenu = popup
        // A menu bar app shows a pop-up menu only while it is the active app: activate it for the
        // menu (the target window is already pinned), then give the previous app back its focus.
        appBeforePopup = NSWorkspace.shared.frontmostApplication
        NSApp.activate(ignoringOtherApps: true)
        let location = NSEvent.mouseLocation
        DispatchQueue.main.async {
            let chosen = popup.popUp(positioning: nil, at: location, in: nil)
            Log.app.info("window menu shown at \(Int(location.x)), \(Int(location.y)); item chosen: \(chosen)")
        }
    }

    private var appBeforePopup: NSRunningApplication?

    private var popupMenu: NSMenu?

    func menuDidClose(_ menu: NSMenu) {
        // The chosen command runs before this: forget the window the menu was for afterwards.
        // Also when the whole menu closes: the Window submenu pins its window when AppKit fills
        // it, and should AppKit ever fill it without showing it, it would never be told closed
        // and every later command would act on that old window.
        guard menu === windowMenu || menu === popupMenu || menu === self.menu else { return }
        let wasPopup = menu === popupMenu
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.engine.commands.pinned = nil
            self.popupMenu = nil
            if wasPopup, NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() {
                self.appBeforePopup?.activate()
            }
            if wasPopup { self.appBeforePopup = nil }
        }
    }

    private func buildWindowMenu(_ windowMenu: NSMenu) {
        windowMenu.removeAllItems()
        let commands = engine.commands
        commands.pinned = nil
        commands.pinned = commands.activeWindow()
        let active = commands.active()
        let manageable = active?.info.isManageable == true
        let resizable = active.map { !$0.info.isFullScreen && !$0.info.isFixedSize && !$0.info.isMinimized } ?? false

        // Which window the commands act on, or why there is none.
        let target: String
        if let active {
            let title = active.info.title.count > 50 ? String(active.info.title.prefix(50)) + "…" : active.info.title
            let why = active.info.isFullScreen ? " (full screen: nothing to do)"
                : !manageable ? " (not a window Fremspace manages)" : ""
            target = "\(WindowCommands.appName(active.info.bundleID)) — \(title)\(why)"
        } else {
            target = "No window to act on"
        }
        let header = NSMenuItem(title: target, action: nil, keyEquivalent: "")
        header.isEnabled = false
        windowMenu.addItem(header)
        windowMenu.addItem(.separator())

        let send = NSMenuItem(title: "Send to desktop", action: nil, keyEquivalent: "")
        let sendMenu = NSMenu()
        sendMenu.autoenablesItems = false
        let available = engine.availableDesktops
        for (display, labels) in commands.desktops() {
            let header = NSMenuItem(title: engine.displayName(display), action: nil, keyEquivalent: "")
            header.isEnabled = false
            sendMenu.addItem(header)
            for (index, label) in labels.enumerated() {
                let desktop = ConfiguredDesktop(display: display, index: index)
                let entry = NSMenuItem(title: "    \(index + 1). \(label)", action: #selector(sendToDesktop(_:)), keyEquivalent: "")
                entry.target = self
                entry.representedObject = desktop
                entry.state = active?.desktop == desktop ? .on : .off
                entry.isEnabled = manageable && available.contains(desktop) && active?.desktop != desktop
                sendMenu.addItem(entry)
            }
        }
        send.submenu = sendMenu
        send.isEnabled = manageable
        windowMenu.addItem(send)

        let lock = NSMenuItem(title: "Lock on this desktop", action: #selector(lockHere), keyEquivalent: "")
        lock.target = self
        lock.isEnabled = manageable && active?.desktop != nil
        windowMenu.addItem(lock)

        let edges = active.map { engine.drawers.edges(forWindow: $0.id) } ?? []
        for edge in [DrawerEdge.left, .right] where edges.contains(edge) {
            let entry = NSMenuItem(title: "Add to \(edge.rawValue) drawer", action: #selector(addToDrawer(_:)), keyEquivalent: "")
            entry.target = self
            entry.representedObject = edge.rawValue
            entry.isEnabled = manageable
            windowMenu.addItem(entry)
        }

        let focusable = commands.focusable()
        let focus = NSMenuItem(title: "Make focusable", action: #selector(toggleFocusable), keyEquivalent: "")
        focus.target = self
        focus.state = focusable == true ? .on : .off
        focus.isEnabled = focusable != nil
        windowMenu.addItem(focus)

        windowMenu.addItem(.separator())
        for quick in WindowCommands.quickCommands {
            let title = ShortcutCatalog.menuTitle(WindowCommands.title(quick), id: ShortcutCatalog.quickID(quick), custom: engine.shortcuts)
            let command = NSMenuItem(title: title, action: #selector(quickResize(_:)), keyEquivalent: "")
            command.target = self
            command.representedObject = quick.rawValue
            command.isEnabled = resizable
            windowMenu.addItem(command)
        }
        let restore = NSMenuItem(title: ShortcutCatalog.menuTitle("Restore previous size", id: ShortcutCatalog.restoreID, custom: engine.shortcuts),
                                 action: #selector(restorePrevious), keyEquivalent: "")
        restore.target = self
        restore.isEnabled = resizable
        windowMenu.addItem(restore)
    }

    @objc private func sendToDesktop(_ sender: NSMenuItem) {
        guard let desktop = sender.representedObject as? ConfiguredDesktop else { return }
        engine.commands.send(to: desktop)
    }

    @objc private func lockHere() { engine.commands.lockOnThisDesktop() }

    @objc private func addToDrawer(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let edge = DrawerEdge(rawValue: raw) else { return }
        engine.commands.addToDrawer(edge)
    }

    @objc private func toggleFocusable() { engine.commands.toggleFocusable() }

    @objc private func quickResize(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let command = QuickResize(rawValue: raw) else { return }
        engine.commands.quick(command)
    }

    @objc private func restorePrevious() { engine.commands.restorePrevious() }

    @objc private func restoreEverything() { engine.loginRestorer.restoreNow() }


    private var moverItem: NSMenuItem?

    /// Says so when windows cannot be sent to another desktop (a macOS update changed SkyLight):
    /// Fremspace then arranges windows where they are.
    private func showMoverAvailability() {
        if let old = moverItem { menu.removeItem(old) }
        moverItem = nil
        guard !engine.canMoveBetweenDesktops else { return }
        let line = NSMenuItem(title: "Moving windows between desktops is unavailable", action: nil, keyEquivalent: "")
        line.isEnabled = false
        menu.insertItem(line, at: 1)
        moverItem = line
    }

    /// The configured desktops of the display under the mouse; the one the shown desktop is now is
    /// checked. Picking another ties the shown desktop to it (when macOS matched them wrongly).
    private func showThisDesktop() {
        let submenu = thisDesktopItem.submenu ?? NSMenu()
        submenu.removeAllItems()
        guard let shown = engine.shownDesktop() else {
            thisDesktopItem.isEnabled = false
            return
        }
        thisDesktopItem.isEnabled = true
        thisDesktopItem.title = "This desktop of \(engine.displayName(shown.display)) is…"
        if shown.uuid.isEmpty {
            let note = NSMenuItem(title: "The first desktop of the main display is matched by position", action: nil,
                                  keyEquivalent: "")
            note.isEnabled = false
            submenu.addItem(note)
        }
        for (index, label) in shown.labels.enumerated() {
            let entry = NSMenuItem(title: "\(index + 1). \(label)", action: #selector(linkThisDesktop(_:)), keyEquivalent: "")
            entry.target = self
            entry.tag = index
            entry.state = shown.current == index ? .on : .off
            entry.isEnabled = !shown.uuid.isEmpty
            entry.representedObject = shown.uuid
            submenu.addItem(entry)
        }
        thisDesktopShownDisplay = shown.display
    }

    private var thisDesktopShownDisplay: DisplayIdentity?

    @objc private func linkThisDesktop(_ sender: NSMenuItem) {
        guard let display = thisDesktopShownDisplay, let uuid = sender.representedObject as? String else { return }
        engine.linkShownDesktop(display: display, uuid: uuid, to: sender.tag)
    }

    private func add(_ title: String, _ action: Selector, key: String = "") {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { entry.keyEquivalentModifierMask = [.control, .option, .command] }
        entry.target = self
        menu.addItem(entry)
    }

    @objc private func reapply() { engine.reapplyCurrentSpaces() }
    @objc private func checkForUpdates() { engine.updates.check?() }
    @objc private func openSettings() { openAdmin() }

    /// The editor, from the menu or ⌃⌥⌘, anywhere.
    func openAdmin() {
        settings.show()
    }

    /// False when the editor has unsaved changes and the owner chose to stay.
    func mayQuit() -> Bool { settings.mayQuit() }

    /// "Recovery": when something went wrong.
    private func recoveryItem() -> NSMenuItem {
        let item = NSMenuItem(title: "Recovery", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for (title, action) in [("Bring every window back on screen", #selector(bringBack)),
                                ("Copy diagnostics", #selector(copyDiagnostics)),
                                ("Dump windows", #selector(dumpWindows)),
                                ("Open config file", #selector(openConfig)),
                                ("Reload config", #selector(reloadConfig))] {
            let entry = NSMenuItem(title: title, action: action, keyEquivalent: "")
            entry.target = self
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let report = NSMenuItem(title: "Report a problem\u{2026}", action: #selector(reportProblem), keyEquivalent: "")
        report.target = self
        submenu.addItem(report)
        item.submenu = submenu
        return item
    }

    @objc private func reportProblem() { Links.open(Links.reportProblem) }

    @objc private func bringBack() { engine.commands.bringEveryWindowBack() }

    @objc private func copyDiagnostics() {
        let text = WindowDump.text(windows: windows) + "\n" + engine.diagnostics()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        engine.commands.notify("Diagnostics copied to the clipboard.")
    }

    @objc private func togglePause() { engine.paused.toggle() }

    @objc private func reloadConfig() { engine.reloadConfig() }

    /// Opens the file in the default editor; when there is none yet, opens its folder. Never
    /// creates or writes the file.
    @objc private func openConfig() {
        let fm = FileManager.default
        if fm.fileExists(atPath: store.url.path) {
            engine.openForOwner(store.url)
        } else {
            let dir = store.url.deletingLastPathComponent()
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            engine.openForOwner(dir)
        }
    }

    /// Writes every window Fremspace can see, with its display and Space, to
    /// ~/Library/Logs/Fremspace/windows.txt and opens it.
    @objc private func dumpWindows() {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Fremspace")
        let url = dir.appendingPathComponent("windows.txt")
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try WindowDump.text(windows: windows).write(to: url, atomically: true, encoding: .utf8)
            engine.openForOwner(url)
        } catch {
            Log.app.error("Dump windows failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// The text of "Dump windows": displays (with the identities a configuration needs), their Spaces,
/// then every window.
enum WindowDump {
    static func text(windows: AXWindows) -> String {
        var lines: [String] = ["Fremspace \(AppVersion.current) — \(Date())", "", "Displays:"]
        let displays = Displays.connected()
        let current = Spaces.current()
        let managed = Spaces.managed()
        for d in displays {
            let i = d.identity
            let desktops = managed.displays.first(where: { $0.uuid == d.uuid })?.desktops.count ?? 0
            let showing = current[i].map { "desktop \($0 + 1)" } ?? "a full-screen Space"
            lines.append("  \(i.name): vendor \(i.vendor) model \(i.model) serial \(i.serial), visible AX \(fmt(d.visibleAX)), \(desktops) desktops, showing \(showing), uuid \(d.uuid)")
        }
        lines += ["", "Windows (current Space of each display):"]
        for (info, element) in windows.windows(onScreen: false) {
            let space = Spaces.spaceIndex(ofWindow: info.id, managed: managed, displays: displays)
            let where_ = space.map { "\($0.display.name) desktop \($0.spaceIndex + 1)" } ?? "no desktop"
            let frame = windows.frame(element).map(fmt) ?? "?"
            var flags: [String] = []
            if !info.isStandard { flags.append("non-standard") }
            if info.isMinimized { flags.append("minimized") }
            if info.isFullScreen { flags.append("full screen") }
            if info.isFixedSize { flags.append("fixed size") }
            if let profile = info.profile { flags.append("profile \(profile)") }
            if isTabbedBrowser(info.bundleID) {
                flags.append("\(windows.identity(of: element, info: info).tabs.count) tabs")
            }
            lines.append("  \(info.id) \(info.bundleID) \"\(info.title)\" frame \(frame) on \(where_)\(flags.isEmpty ? "" : " [\(flags.joined(separator: ", "))]")")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func fmt(_ r: CGRect) -> String {
        "(\(Int(r.minX)), \(Int(r.minY)), \(Int(r.width))×\(Int(r.height)))"
    }
}
