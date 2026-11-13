import AppKit
import FremspaceCore

/// The menu bar. Fremspace is a menu bar app, but while its editor is open it is a regular app
/// (`SettingsWindow.show`) and has one: it lists what the window can do, with the keys, where a Mac
/// user looks for them. The text items are also what lets ⌘C, ⌘V and ⌘W work in the window at all.
///
/// Every item goes to the first responder. The editor's window answers for its own
/// (`SettingsWindow`, below), and an item nobody answers for is dimmed.
enum MainMenu {
    static func make() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu("Fremspace", [
            item("About Fremspace", #selector(NSApplication.orderFrontStandardAboutPanel(_:))),
            item("Check for Updates\u{2026}", #selector(SettingsWindow.checkForUpdates(_:))),
            .separator(),
            item("Hide Fremspace", #selector(NSApplication.hide(_:)), "h"),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option]),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:))),
            .separator(),
            item("Quit Fremspace", #selector(NSApplication.terminate(_:)), "q"),
        ]))
        main.addItem(submenu("File", [
            item("Save", #selector(SettingsWindow.saveEdits(_:)), "s"),
            item("Revert to Saved", #selector(SettingsWindow.revertEdits(_:))),
            .separator(),
            item("Close", #selector(NSWindow.performClose(_:)), "w"),
        ]))
        main.addItem(submenu("Edit", [
            item("Undo", #selector(SettingsWindow.undoEdit(_:)), "z"),
            item("Redo", #selector(SettingsWindow.redoEdit(_:)), "z", [.command, .shift]),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x"),
            item("Copy", #selector(NSText.copy(_:)), "c"),
            item("Paste", #selector(NSText.paste(_:)), "v"),
            item("Select All", #selector(NSText.selectAll(_:)), "a"),
            .separator(),
            item("Find\u{2026}", #selector(SettingsWindow.findInSettings(_:)), "f"),
        ]))

        var layout: [NSMenuItem] = [
            item("Split Left and Right", #selector(SettingsWindow.splitSlot(_:)), "d", tag: 0),
            item("Split Top and Bottom", #selector(SettingsWindow.splitSlot(_:)), "d", [.command, .shift], tag: 1),
            item("Remove Slot", #selector(SettingsWindow.removeSlot(_:)), "\u{8}"),
            .separator(),
        ]
        // The tag of each of these is a direction: left, right, up, down.
        for (tag, name) in ["on the Left", "on the Right", "Above", "Below"].enumerated() {
            layout.append(item("Select the Slot \(name)", #selector(SettingsWindow.selectNeighbourSlot(_:)), arrows[tag], [.command, .option], tag: tag))
        }
        layout.append(.separator())
        for (tag, name) in ["Narrower", "Wider", "Shorter", "Taller"].enumerated() {
            layout.append(item("Make the Slot \(name)", #selector(SettingsWindow.resizeSlot(_:)), arrows[tag], [.command, .option, .shift], tag: tag))
        }
        layout += [
            .separator(),
            item("Capture This Desktop", #selector(SettingsWindow.captureDesktop(_:))),
            .separator(),
            item("Add a Desktop", #selector(SettingsWindow.addDesktop(_:)), "t"),
            // The desktops are the tabs of the window: the keys every tabbed app has. Not ⇧⌘] and ⇧⌘[,
            // which cannot be typed on a keyboard that has its brackets behind ⌥.
            item("Next Desktop", #selector(SettingsWindow.stepDesktop(_:)), "\t", [.control], tag: 1),
            item("Previous Desktop", #selector(SettingsWindow.stepDesktop(_:)), "\t", [.control, .shift], tag: -1),
        ]
        // ⌘1 to ⌘9: named after the desktops of the display being edited when the menu opens.
        for number in 1...9 {
            layout.append(item("Desktop \(number)", #selector(SettingsWindow.showDesktop(_:)), "\(number)", tag: number - 1))
        }
        layout += [
            .separator(),
            item("Next Display", #selector(SettingsWindow.stepDisplay(_:)), "\t", [.control, .option], tag: 1),
            item("Previous Display", #selector(SettingsWindow.stepDisplay(_:)), "\t", [.control, .option, .shift], tag: -1),
        ]
        main.addItem(submenu("Layout", layout))

        let window = submenu("Window", [
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m"),
            item("Zoom", #selector(NSWindow.performZoom(_:))),
        ])
        main.addItem(window)
        NSApp.windowsMenu = window.submenu
        return main
    }

    /// What in the menus follows the session and cannot wait for a menu to open, because ⌘1 to ⌘9 are
    /// typed without one: the desktops of the display being edited, each under its name, and the
    /// updates item, which a build without an updater does not show.
    static func reflect(desktops: [String], selected: Int?, updates: Bool) {
        for item in NSApp.mainMenu?.items.flatMap({ $0.submenu?.items ?? [] }) ?? [] {
            switch item.action {
            case #selector(SettingsWindow.showDesktop(_:)):
                item.isHidden = !desktops.indices.contains(item.tag)
                guard desktops.indices.contains(item.tag) else { continue }
                item.title = desktops[item.tag].isEmpty ? "Desktop \(item.tag + 1)" : desktops[item.tag]
                item.state = item.tag == selected ? .on : .off
            case #selector(SettingsWindow.checkForUpdates(_:)):
                item.isHidden = !updates
            default:
                break
            }
        }
    }

    /// The arrow keys as key equivalents, in the order of the tags: left, right, up, down.
    private static let arrows = [NSLeftArrowFunctionKey, NSRightArrowFunctionKey, NSUpArrowFunctionKey, NSDownArrowFunctionKey]
        .map { String(UnicodeScalar($0)!) }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    private static func item(_ title: String, _ action: Selector, _ key: String = "",
                             _ modifiers: NSEvent.ModifierFlags = .command, tag: Int = 0) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.tag = tag
        return item
    }
}

// MARK: - What the editor's window answers for

extension SettingsWindow: NSMenuItemValidation {
    @objc func saveEdits(_ sender: Any?) { session?.save() }
    @objc func revertEdits(_ sender: Any?) { session?.revert() }
    @objc func undoEdit(_ sender: Any?) { session?.undo() }
    @objc func redoEdit(_ sender: Any?) { session?.redo() }
    @objc func findInSettings(_ sender: Any?) { session?.searchRequests += 1 }
    @objc func checkForUpdates(_ sender: Any?) { session?.engine.updates.check?() }

    @objc func splitSlot(_ sender: NSMenuItem) {
        guard let session, let slot = session.selection.slot else { return }
        session.split(slot: slot, along: sender.tag == 0 ? .vertical : .horizontal)
    }

    @objc func removeSlot(_ sender: Any?) {
        guard let session, let slot = session.selection.slot else { return }
        session.remove(slot: slot)
    }

    @objc func selectNeighbourSlot(_ sender: NSMenuItem) {
        session?.selectNeighbourSlot([Direction.left, .right, .up, .down][sender.tag])
    }

    @objc func resizeSlot(_ sender: NSMenuItem) {
        // Narrower, wider: by a vertical divider. Shorter, taller: by a horizontal one.
        session?.stepSelectedSlot(by: sender.tag < 2 ? .vertical : .horizontal, grow: sender.tag % 2 == 1)
    }

    @objc func captureDesktop(_ sender: Any?) { session?.captureDesktop() }
    @objc func addDesktop(_ sender: Any?) { session?.addDesktop() }
    @objc func stepDesktop(_ sender: NSMenuItem) { session?.stepDesktop(by: sender.tag) }
    @objc func showDesktop(_ sender: NSMenuItem) { session?.select(desktop: sender.tag) }
    @objc func stepDisplay(_ sender: NSMenuItem) { session?.stepDisplay(by: sender.tag) }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        guard let session else { return false }
        // Whether the layout of a desktop (or of a drawer) is what the window shows.
        let editing = session.settingsPage == nil && session.displaySpec?.ignored == false
        // A key that means something in a text field is the field's while one is being typed in:
        // ⌘⌫ there deletes to the start of the line, it does not remove a slot.
        let typing = window?.firstResponder is NSText
        let slot = editing ? session.selection.slot : nil
        let desktops = editing ? session.displaySpec?.spaces ?? [] : []
        switch item.action {
        case #selector(saveEdits(_:)): return session.isDirty && session.loadError == nil
        case #selector(revertEdits(_:)): return session.isDirty
        case #selector(undoEdit(_:)): return session.canUndo
        case #selector(redoEdit(_:)): return session.canRedo
        case #selector(checkForUpdates(_:)): return session.engine.updates.isAvailable
        case #selector(splitSlot(_:)): return slot != nil && session.canSplitSelected(item.tag == 0 ? .vertical : .horizontal)
        case #selector(removeSlot(_:)): return slot != nil && !typing && (session.editedLayout?.slots.count ?? 0) > 1
        case #selector(selectNeighbourSlot(_:)): return editing && !typing && (session.editedLayout?.slots.count ?? 0) > 0
        case #selector(resizeSlot(_:)): return slot != nil && !typing
        case #selector(captureDesktop(_:)): return editing && session.selection.drawer == nil && session.spaceSpec != nil
        case #selector(addDesktop(_:)): return editing
        case #selector(stepDesktop(_:)): return desktops.count > 1
        case #selector(showDesktop(_:)): return desktops.indices.contains(item.tag)
        case #selector(stepDisplay(_:)): return session.settingsPage == nil && (session.configuration?.displays.count ?? 0) > 1
        default: return true
        }
    }
}

// MARK: - What the keyboard does in the layout

extension EditSession {
    /// The slot beside the selected one, as the screen shows them; with none selected, the first.
    func selectNeighbourSlot(_ direction: Direction) {
        guard let layout = editedLayout, !layout.slots.isEmpty else { return }
        guard let current = selection.slot else {
            selection.slot = layout.slots.min { ($0.rect.y, $0.rect.x) < ($1.rect.y, $1.rect.x) }?.id
            return
        }
        // Unit rectangles as frames: up is smaller y, as `neighbourSlot` wants.
        let frames = Dictionary(layout.slots.map { ($0.id, CGRect(x: $0.rect.x, y: $0.rect.y, width: $0.rect.w, height: $0.rect.h)) },
                                uniquingKeysWith: { first, _ in first })
        if let next = neighbourSlot(from: current, toward: direction, frames: frames) { selection.slot = next }
    }

    /// The selected slot one stop larger or smaller, as a drag of its divider would make it.
    func stepSelectedSlot(by axis: CoreAxis, grow: Bool) {
        guard let id = selection.slot, let layout = editedLayout else { return }
        let visible = geometry(of: selection.display).visible
        let container = editedContainer
        let length = axis == .vertical ? CGFloat(container.w) * visible.width : CGFloat(container.h) * visible.height
        let stepped = FremspaceCore.stepped(layout, slot: id, by: axis, grow: grow, length: length)
        guard stepped != layout else { return NSSound.beep() }
        checkpoint()
        setEditedLayout(stepped)
    }

    /// The next or the previous desktop of the display, round and round like tabs.
    func stepDesktop(by step: Int) {
        guard let count = displaySpec?.spaces.count, count > 1 else { return }
        select(desktop: (selection.desktop + step + count) % count)
    }

    /// The next or the previous display of the configuration.
    func stepDisplay(by step: Int) {
        guard let displays = configuration?.displays, displays.count > 1,
              let index = displays.firstIndex(where: { $0.identity == selection.display }) else { return }
        select(display: displays[(index + step + displays.count) % displays.count].identity)
    }
}
