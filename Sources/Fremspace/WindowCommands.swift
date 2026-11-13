import AppKit
import Carbon.HIToolbox
import FremspaceCore
import UserNotifications

/// Day-to-day commands on the active window (spec Part B): Rectangle's quick resizes, and (Task 10,
/// 11) the commands that send, lock or recover windows.
final class WindowCommands {
    private unowned let engine: Engine
    private let windows: AXWindows
    /// The frame each window had before its first quick resize, for "Restore".
    private var beforeQuick: [UInt32: CGRect] = [:]

    init(engine: Engine, windows: AXWindows) {
        self.engine = engine
        self.windows = windows
    }

    /// The quick sizes in the order the window menu and the Shortcuts page show them. They have no
    /// default shortcut: ⌃⌥ plus a key is what Rectangle and others already use, and the keys of a
    /// tool somebody installed first are not Fremspace's to take.
    static let quickCommands: [QuickResize] = [
        .leftHalf, .rightHalf, .topHalf, .bottomHalf, .maximize, .center,
        .firstThird, .centerThird, .lastThird, .firstTwoThirds, .lastTwoThirds,
    ]

    static func title(_ command: QuickResize) -> String {
        switch command {
        case .leftHalf: "Left half"
        case .rightHalf: "Right half"
        case .topHalf: "Top half"
        case .bottomHalf: "Bottom half"
        case .maximize: "Maximize"
        case .center: "Center"
        case .firstThird: "First third"
        case .centerThird: "Center third"
        case .lastThird: "Last third"
        case .firstTwoThirds: "First two thirds"
        case .lastTwoThirds: "Last two thirds"
        }
    }

    // MARK: - Quick resize

    /// Resizes the active window. A window in a slot leaves it and floats until ⌃⌥⌘R.
    func quick(_ command: QuickResize) {
        guard let (id, element) = activeWindow(), let frame = windows.frame(element),
              let display = Self.display(of: frame) else { return NSSound.beep() }
        if beforeQuick[id] == nil { beforeQuick[id] = frame }
        engine.moveByCommand(id, element, to: quickFrame(command, window: frame, visible: display.visibleAX))
    }

    /// Gives the active window back the frame it had before its first quick resize.
    func restorePrevious() {
        guard let (id, element) = activeWindow(), let frame = beforeQuick.removeValue(forKey: id) else {
            return NSSound.beep()
        }
        engine.moveByCommand(id, element, to: frame)
    }

    // MARK: - Window commands

    /// The active window, where it is, and which configured desktop that is.
    struct Active {
        var id: UInt32
        var element: AXUIElement
        var info: WindowInfo
        /// Nil for a full-screen window or one on every desktop.
        var space: SpaceKey?
        var desktop: ConfiguredDesktop?
        var frame: CGRect
    }

    func active() -> Active? {
        guard let (id, element) = activeWindow(), let frame = windows.frame(element) else { return nil }
        let space = Spaces.spaceIndex(ofWindow: id)
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        guard let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let info = windows.info(for: element, pid: pid, bundleID: bundleID) else { return nil }
        return Active(id: id, element: element, info: info, space: space, desktop: space.flatMap { engine.configuredDesktop($0) }, frame: frame)
    }

    /// "Send to desktop": the window goes there; its lock does not pull it back.
    func send(to desktop: ConfiguredDesktop) {
        guard let window = active(), window.info.isManageable else { return NSSound.beep() }
        engine.router.send(window.id, to: desktop, byCommand: true)
    }

    /// "Lock on this desktop": a locked slot at the window's frame (or the slot it overlaps most takes
    /// its app), saved in the configuration.
    func lockOnThisDesktop() {
        guard let window = active(), window.info.isManageable, let desktop = window.desktop,
              let display = Displays.connected().first(where: { $0.identity == window.space?.display }) else {
            notify("This desktop is not in the configuration: nothing to lock.")
            return NSSound.beep()
        }
        var label = ""
        var slotID = ""
        var noRoom = false
        let saved = editConfiguration(desktop) { space in
            guard let result = lockHere(layout: space.layout, window: window.info, frame: window.frame,
                                        visible: display.visibleAX) else {
                noRoom = true
                return false
            }
            space.layout = result.layout
            label = space.label
            slotID = result.slotID
            return true
        }
        if noRoom {
            notify("No slot can be made where this window is: put it clear of the other slots, or well onto the one that should take it.")
        }
        guard saved else { return }
        engine.unrelease(window.id)
        notify("\(Self.appName(window.info.bundleID)) locked on \(label) (slot \(slotID)).")
    }

    /// "Add to left / right drawer": parks the window in that drawer of its display.
    func addToDrawer(_ edge: DrawerEdge) {
        guard let window = active() else { return NSSound.beep() }
        engine.drawers.send(window.element, edge: edge)
    }

    /// The active window's slot, and whether it is focusable (nil: not in a slot).
    func focusable() -> Bool? {
        guard let window = active(), let held = engine.slot(of: window.id), let desktop = engine.configuredDesktop(held.space),
              let spec = spaceSpec(desktop) else { return nil }
        return focusSlots(spec).contains { $0.id == held.slotID }
    }

    /// "Make focusable": the option of the active window's slot, saved.
    func toggleFocusable() {
        guard let window = active(), let held = engine.slot(of: window.id),
              let desktop = engine.configuredDesktop(held.space) else { return NSSound.beep() }
        var on = false
        let saved = editConfiguration(desktop) { space in
            guard space.layout != nil else { return false }
            on = !focusSlots(space).contains { $0.id == held.slotID }
            space = settingFocus(space, slot: held.slotID, on: on)
            return true
        }
        if saved { notify("Slot \(held.slotID) is \(on ? "now" : "no longer") focusable.") }
    }

    /// Replaces the layout of a desktop in the configuration file (an edge dragged between two slots,
    /// two slots swapped). False when nothing changed or the file could not be written.
    func setLayout(_ layout: Layout, of desktop: ConfiguredDesktop) -> Bool {
        editConfiguration(desktop) { space in
            guard space.layout != nil, space.layout != layout else { return false }
            space.layout = layout
            return true
        }
    }

    /// The configured desktops of the active configuration, per display (for "Send to desktop").
    func desktops() -> [(display: DisplayIdentity, labels: [String])] {
        guard let configuration = engine.activeConfiguration else { return [] }
        return configuration.displays.filter { !$0.ignored }.map { ($0.identity, $0.spaces.map(\.label)) }
    }

    private func spaceSpec(_ desktop: ConfiguredDesktop) -> SpaceSpec? {
        guard let configuration = engine.activeConfiguration,
              let display = displaySpec(for: desktop.display, in: configuration),
              display.spaces.indices.contains(desktop.index) else { return nil }
        return display.spaces[desktop.index]
    }

    /// Reads the configuration file, changes one desktop of the active configuration, saves it
    /// (previous file kept as .bak) and reloads. An unreadable file is refused, like the editor does.
    private func editConfiguration(_ desktop: ConfiguredDesktop, _ change: (inout SpaceSpec) -> Bool) -> Bool {
        let store = engine.configStore
        // Written now, the file would no longer be the one the editor read: its Save would be
        // refused as "changed outside the editor", and Revert, the only way out, drops the edits.
        guard !editorHasUnsavedChanges else {
            notify("The editor has changes that are not saved: save or revert them, then ask again.")
            NSSound.beep()
            return false
        }
        do {
            let original = try store.load()
            var config = original
            guard let c = config.configurations.firstIndex(where: { $0.id == engine.activeConfigurationID }),
                  let d = config.configurations[c].displays.firstIndex(where: { $0.identity == desktop.display }),
                  config.configurations[c].displays[d].spaces.indices.contains(desktop.index) else {
                notify("This desktop is not in the configuration file.")
                return false
            }
            guard change(&config.configurations[c].displays[d].spaces[desktop.index]) else {
                NSSound.beep()
                return false
            }
            try store.save(config, expecting: original)
            engine.configurationSaved()
            return true
        } catch {
            Log.app.error("configuration not changed: \(String(describing: error), privacy: .public)")
            notify("The configuration file could not be changed: \(error)")
            return false
        }
    }

    /// The editor's window carries the dot of an edited document while its configuration differs
    /// from the file (`SettingsWindow`): that is read here, as anyone looking at the window would.
    /// A window in the Dock still holds its changes; one that was closed no longer counts.
    private var editorHasUnsavedChanges: Bool {
        NSApp.windows.contains { ($0.isVisible || $0.isMiniaturized) && $0.isDocumentEdited }
    }

    private var notificationsAllowed: Bool?

    /// A short confirmation in Notification Center (logged too).
    func notify(_ text: String) {
        Log.app.notice("\(text, privacy: .public)")
        let center = UNUserNotificationCenter.current()
        let post = {
            let content = UNMutableNotificationContent()
            content.title = "Fremspace"
            content.body = text
            center.add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
        }
        if notificationsAllowed == true { return post() }
        center.requestAuthorization(options: [.alert]) { granted, _ in
            DispatchQueue.main.async {
                self.notificationsAllowed = granted
                if granted { post() }
            }
        }
    }

    static func appName(_ bundleID: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)?.deletingPathExtension().lastPathComponent
            ?? bundleID
    }

    // MARK: - Recovery

    /// Drawer members come back, and every window of the shown desktops mostly off screen is moved
    /// onto the display it overlaps most.
    func bringEveryWindowBack() {
        engine.drawers.restoreAll()
        let displays = Displays.connected().map(\.visibleAX)
        var moved = 0
        for (info, element) in windows.windows(onScreen: false) where info.isStandard && !info.isMinimized && !info.isFullScreen {
            guard let frame = windows.frame(element), let target = onScreenFrame(frame, displays: displays) else { continue }
            engine.moveByCommand(info.id, element, to: target)
            moved += 1
        }
        notify(moved == 0 ? "Every window is on screen." : "\(moved) window\(moved == 1 ? "" : "s") brought back on screen.")
    }

    // MARK: - Helpers

    /// The window a menu was opened for: its commands act on it even if the menu took the focus.
    var pinned: (id: UInt32, element: AXUIElement)?

    func activeWindow() -> (id: UInt32, element: AXUIElement)? {
        if let pinned { return pinned }
        guard let element = windows.focusedWindow(), let id = AXWindows.windowID(element) else { return nil }
        return (id, element)
    }

    /// The display a frame is mostly on.
    static func display(of frame: CGRect) -> Displays.Connected? {
        let displays = Displays.connected()
        return displays.max { area($0.frameAX.intersection(frame)) < area($1.frameAX.intersection(frame)) }
            .flatMap { area($0.frameAX.intersection(frame)) > 0 ? $0 : displays.first }
    }

    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
