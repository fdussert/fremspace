import AppKit
import FremspaceCore

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = ConfigStore()
    private let windows = AXWindows()
    private let observer = WindowObserver()
    private lazy var engine = Engine(store: store, windows: windows, observer: observer)
    #if FREMSPACE_SPARKLE
    private var updater: Updater?
    #endif
    private var menu: StatusMenu?
    private var hotkeys: Hotkeys?
    private var hotkeyActions: [String: () -> Void] = [:]
    private lazy var palette = Palette(engine: engine, windows: windows)
    private let hyper = HyperKey()
    private lazy var notch = NotchController(engine: engine, palette: palette)

    /// Registers every command's shortcut: the owner's choice from the config file, else the default.
    private func registerHotkeys() {
        guard let hotkeys else { return }
        hotkeys.unregisterAll()
        let effective = ShortcutCatalog.effective(engine.shortcuts)
        var failed: [String] = []
        var refused: [String] = []
        for entry in ShortcutCatalog.entries {
            guard let shortcut = effective[entry.id], let combo = ShortcutCatalog.combo(shortcut),
                  let action = hotkeyActions[entry.id] else { continue }
            // From a file edited by hand: without ⌃, ⌥ or ⌘, or with a modifier that is not one,
            // it would be taken from every app on a key the owner did not mean.
            guard shortcut.isUsable else {
                refused.append(entry.title)
                Log.app.notice("shortcut of \(entry.id, privacy: .public) in the config file is not usable; not registered")
                continue
            }
            let label = ShortcutCatalog.label(shortcut)
            if !hotkeys.register(combo, label: label, action) { failed.append(label) }
        }
        menu?.showFailedHotkeys(failed)
        menu?.showRefusedShortcuts(refused)
        applyHyperKey(effective)
        // The settings of the notch and of the previews are in the config file too.
        notch.refresh()
        WindowPreviews.shared.set(enabled: engine.windowPreviews)
    }

    /// The Hyper key follows the general setting, and runs the commands whose shortcut is ⌃⌥⌘ + key.
    private func applyHyperKey(_ effective: [String: Shortcut]) {
        hyper.command = { [weak self] keyCode, shift in
            guard case .run(let id) = hyperOutcome(keyCode: keyCode, shift: shift, effective: effective) else { return nil }
            return self?.hotkeyActions[id]
        }
        let on = engine.hyperKey && hyper.set(true)
        if !on { hyper.set(false) }
        ShortcutCatalog.hyperOn = on
        if engine.hyperKey, !on, HyperKey.isPossible, !hyperRetryPending {
            // Accessibility was not granted yet: tried again once the engine runs. One try at a
            // time, and of the Hyper key alone: each try used to register every hot key again
            // (also while a shortcut was being recorded) and to start a chain of its own, as did
            // every reload of the configuration.
            hyperRetryPending = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
                guard let self else { return }
                self.hyperRetryPending = false
                guard self.engine.hyperKey, !self.hyper.isOn else { return }
                self.applyHyperKey(ShortcutCatalog.effective(self.engine.shortcuts))
            }
        }
    }
    private var hyperRetryPending = false
    private var termSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        Permissions.requestAccessibilityIfNeeded()
        #if FREMSPACE_SPARKLE
        // Before the menu, which offers "Check for Updates…" only when there is an updater. A build
        // without the public key could never accept an update, and Sparkle would complain at
        // every launch: no updater.
        if let key = Bundle.main.object(forInfoDictionaryKey: "SUPublicEDKey") as? String, !key.isEmpty {
            let updater = Updater()
            self.updater = updater
            engine.updates.check = { [weak updater] in updater?.checkForUpdates() }
            engine.updates.automaticChecks = { [weak updater] in updater?.automaticallyChecks ?? false }
            engine.updates.setAutomaticChecks = { [weak updater] on in updater?.automaticallyChecks = on }
        }
        #endif
        let menu = StatusMenu(windows: windows, engine: engine, store: store)
        self.menu = menu
        engine.onStatusChange = { [weak menu] status in menu?.show(status) }
        engine.onGlyphChange = { [weak menu] glyph in menu?.show(glyph) }
        engine.onDesktopChange = { [weak self] in self?.notch.desktopChanged() }
        engine.start()

        hyper.record = { [weak self] in self?.engine.hyperMapping }
        hyper.remember = { [weak self] record in self?.engine.rememberHyperMapping(record) }
        hotkeys = Hotkeys()
        let commands = engine.commands
        hotkeyActions = [
            "focusToggle": { [weak self] in self?.engine.toggleFocusOnFrontmostSpace() },
            "reapply": { [weak self] in self?.engine.reapplyCurrentSpaces() },
            "pause": { [weak self] in self?.engine.paused.toggle() },
            "openAdmin": { [weak menu] in menu?.openAdmin() },
            "windowMenu": { [weak menu] in menu?.popUpWindowMenu() },
            "drawerLeft": { [weak self] in self?.engine.drawers.toggleOnDisplayUnderMouse(.left) },
            "drawerRight": { [weak self] in self?.engine.drawers.toggleOnDisplayUnderMouse(.right) },
            "drawerSendLeft": { [weak self] in self?.engine.drawers.sendOrTakeOutActiveWindow(.left) },
            "drawerSendRight": { [weak self] in self?.engine.drawers.sendOrTakeOutActiveWindow(.right) },
            "stackNext": { [weak self] in self?.engine.showNextInStack(forward: true) },
            "stackPrevious": { [weak self] in self?.engine.showNextInStack(forward: false) },
            "splitNew": { [weak self] in self?.engine.splitWithNewWindow() },
            "slotLeft": { [weak self] in self?.engine.activateNeighbourSlot(.left) },
            "slotRight": { [weak self] in self?.engine.activateNeighbourSlot(.right) },
            "slotUp": { [weak self] in self?.engine.activateNeighbourSlot(.up) },
            "slotDown": { [weak self] in self?.engine.activateNeighbourSlot(.down) },
            "slotSwapLeft": { [weak self] in self?.engine.swapWithNeighbourSlot(.left) },
            "slotSwapRight": { [weak self] in self?.engine.swapWithNeighbourSlot(.right) },
            "slotSwapUp": { [weak self] in self?.engine.swapWithNeighbourSlot(.up) },
            "slotSwapDown": { [weak self] in self?.engine.swapWithNeighbourSlot(.down) },
            ShortcutCatalog.restoreID: { commands.restorePrevious() },
            "palette": { [weak self] in self?.palette.toggle() },
        ]
        for number in 1...Hotkeys.scenes.count {
            hotkeyActions["scene.\(number)"] = { [weak self] in self?.palette.showScene(number: number) }
        }
        for command in QuickResize.allCases {
            hotkeyActions[ShortcutCatalog.quickID(command)] = { commands.quick(command) }
        }
        // The palette lists every command but itself, with the owner's shortcuts.
        palette.commands = { [weak self] in
            let custom = self?.engine.shortcuts ?? [:]
            // Scenes are listed by their name, not as "Show scene 1".
            return ShortcutCatalog.entries.filter { $0.id != "palette" && !$0.id.hasPrefix("scene.") }.map { entry in
                let label = ShortcutCatalog.label(of: entry.id, custom: custom)
                return Palette.Command(id: entry.id, title: entry.id == "openAdmin" ? "Open the Fremspace admin" : entry.title,
                                       shortcut: label == "None" ? "" : label)
            }
        }
        palette.run = { [weak self] id in self?.hotkeyActions[id]?() }
        engine.slotWindows = { [weak self] desktop in self?.palette.slotWindows(on: desktop) ?? [:] }
        registerHotkeys()
        // The owner's shortcuts are in the config file: registered again whenever it is read.
        engine.onConfigChanged = { [weak self] in self?.registerHotkeys() }
        menu.suspendHotkeys = { [weak self] suspended in
            self?.hyper.commandsSuspended = suspended
            if suspended { self?.hotkeys?.unregisterAll() } else { self?.registerHotkeys() }
        }

        // `pkill` (SIGTERM), Ctrl-C (SIGINT) and a closed terminal (SIGHUP) skip
        // applicationWillTerminate: bring drawer members back first there too. A crash is covered by
        // the parked-windows file instead (see DrawerController.recoverAfterCrash).
        termSources = [SIGTERM, SIGINT, SIGHUP].map { number in
            signal(number, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
            source.setEventHandler { [weak self] in
                self?.hyper.stop()
                self?.engine.drawers.restoreAll()
                self?.engine.saveStateNow()
                exit(0)
            }
            source.resume()
            return source
        }
    }

    /// `fremspace://` links, from another tool or `open -g fremspace://run/palette`.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            switch parseLink(url) {
            case .run(let id):
                // A link is opened by any app without a prompt: see `linkMayRun` for what it may not do.
                guard linkMayRun(id) else {
                    Log.app.notice("link: \(id, privacy: .public) is not a command a link may run")
                    NSSound.beep()
                    continue
                }
                guard let action = hotkeyActions[id] else {
                    Log.app.notice("link: no command named \(id, privacy: .public)")
                    continue
                }
                Log.app.info("link: command \(id, privacy: .public)")
                action()
            case .desktop(let name):
                if !palette.showDesktop(named: name) { Log.app.notice("link: no desktop named \(name, privacy: .public)") }
            case .scene(let name):
                if !palette.showScene(named: name) { Log.app.notice("link: no scene named \(name, privacy: .public)") }
            case nil:
                Log.app.notice("link not understood: \(url.absoluteString, privacy: .public)")
            }
        }
    }

    /// A menu bar app has no visible menu bar, but AppKit still routes ⌘C / ⌘V / ⌘Z / ⌘W through the
    /// main menu: without one, the Settings text fields cannot copy, paste or undo.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        appItem.submenu?.addItem(withTitle: "Quit Fremspace", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)
        let windowItem = NSMenuItem()
        windowItem.submenu = NSMenu(title: "Window")
        windowItem.submenu?.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        main.addItem(windowItem)
        NSApp.mainMenu = main
    }

    func applicationWillTerminate(_ notification: Notification) {
        hyper.stop()
        engine.drawers.restoreAll()
        engine.saveStateNow()
    }
}
