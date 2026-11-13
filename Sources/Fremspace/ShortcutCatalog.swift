import AppKit
import Carbon.HIToolbox
import FremspaceCore

/// Every command that has a global shortcut: its id (the key in the config file's `shortcuts`), its
/// name in Settings and its default. The owner's choices replace the defaults one by one.
enum ShortcutCatalog {
    struct Entry {
        let id: String
        let title: String
        let group: String
        /// Nil: the command has no shortcut until the owner gives it one.
        let fallback: Hotkeys.Combo?

        var defaultShortcut: Shortcut { fallback.map(ShortcutCatalog.shortcut) ?? Shortcut(keyCode: nil) }
    }

    static let entries: [Entry] = {
        var list: [Entry] = [
            Entry(id: "reapply", title: "Re-apply the layouts", group: "General", fallback: Hotkeys.reapply),
            Entry(id: "pause", title: "Pause, and back", group: "General", fallback: Hotkeys.pause),
            Entry(id: "openAdmin", title: "Open this window", group: "General", fallback: Hotkeys.openAdmin),
            Entry(id: "windowMenu", title: "Window menu, under the pointer", group: "General", fallback: Hotkeys.windowMenu),
            Entry(id: "palette", title: "Palette: find a window, an app, a desktop, a command", group: "General",
                  fallback: Hotkeys.palette),
            Entry(id: "focusToggle", title: "Enlarge the Focus slot, and back", group: "Slots", fallback: Hotkeys.focusToggle),
            Entry(id: "slotLeft", title: "Go to the slot on the left", group: "Slots", fallback: Hotkeys.slotLeft),
            Entry(id: "slotRight", title: "Go to the slot on the right", group: "Slots", fallback: Hotkeys.slotRight),
            Entry(id: "slotUp", title: "Go to the slot above", group: "Slots", fallback: Hotkeys.slotUp),
            Entry(id: "slotDown", title: "Go to the slot below", group: "Slots", fallback: Hotkeys.slotDown),
            Entry(id: "slotSwapLeft", title: "Swap with the slot on the left", group: "Slots", fallback: Hotkeys.slotSwapLeft),
            Entry(id: "slotSwapRight", title: "Swap with the slot on the right", group: "Slots", fallback: Hotkeys.slotSwapRight),
            Entry(id: "slotSwapUp", title: "Swap with the slot above", group: "Slots", fallback: Hotkeys.slotSwapUp),
            Entry(id: "slotSwapDown", title: "Swap with the slot below", group: "Slots", fallback: Hotkeys.slotSwapDown),
            Entry(id: "stackNext", title: "Next window stacked in the slot", group: "Slots", fallback: Hotkeys.stackNext),
            Entry(id: "stackPrevious", title: "Previous window stacked in the slot", group: "Slots", fallback: Hotkeys.stackPrevious),
            Entry(id: "splitNew", title: "A second window of the app beside this one, and back", group: "Slots", fallback: Hotkeys.splitNew),
            Entry(id: "drawerLeft", title: "Open or close the left drawer", group: "Drawers", fallback: Hotkeys.drawerLeft),
            Entry(id: "drawerRight", title: "Open or close the right drawer", group: "Drawers", fallback: Hotkeys.drawerRight),
            Entry(id: "drawerSendLeft", title: "Send to the left drawer, or take out", group: "Drawers", fallback: Hotkeys.drawerSendLeft),
            Entry(id: "drawerSendRight", title: "Send to the right drawer, or take out", group: "Drawers", fallback: Hotkeys.drawerSendRight),
        ]
        list += Hotkeys.scenes.enumerated().map {
            Entry(id: "scene.\($0.offset + 1)", title: "Show scene \($0.offset + 1)", group: "Scenes", fallback: $0.element)
        }
        list += WindowCommands.quickCommands.map {
            Entry(id: quickID($0), title: WindowCommands.title($0), group: "Resize the active window", fallback: nil)
        }
        list.append(Entry(id: restoreID, title: "Restore the previous size", group: "Resize the active window", fallback: nil))
        return list
    }()

    static func quickID(_ command: QuickResize) -> String { "quick.\(command.rawValue)" }
    static let restoreID = "quick.restore"

    static let groups: [String] = {
        var seen: [String] = []
        for entry in entries where !seen.contains(entry.group) { seen.append(entry.group) }
        return seen
    }()

    /// The shortcut of each command: the owner's choice, else the default.
    static func effective(_ custom: [String: Shortcut]) -> [String: Shortcut] {
        Dictionary(uniqueKeysWithValues: entries.map { ($0.id, custom[$0.id] ?? $0.defaultShortcut) })
    }

    static func shortcut(_ combo: Hotkeys.Combo) -> Shortcut {
        var names: [String] = []
        if combo.modifiers & UInt32(controlKey) != 0 { names.append("control") }
        if combo.modifiers & UInt32(optionKey) != 0 { names.append("option") }
        if combo.modifiers & UInt32(shiftKey) != 0 { names.append("shift") }
        if combo.modifiers & UInt32(cmdKey) != 0 { names.append("command") }
        return Shortcut(keyCode: combo.keyCode, modifiers: names)
    }

    /// Nil for a command without shortcut.
    static func combo(_ shortcut: Shortcut) -> Hotkeys.Combo? {
        guard let keyCode = shortcut.keyCode else { return nil }
        var mask = 0
        if shortcut.modifiers.contains("control") { mask |= controlKey }
        if shortcut.modifiers.contains("option") { mask |= optionKey }
        if shortcut.modifiers.contains("shift") { mask |= shiftKey }
        if shortcut.modifiers.contains("command") { mask |= cmdKey }
        return (keyCode, UInt32(mask))
    }

    static func shortcut(from event: NSEvent) -> Shortcut {
        var names: [String] = []
        let flags = event.modifierFlags
        if flags.contains(.control) { names.append("control") }
        if flags.contains(.option) { names.append("option") }
        if flags.contains(.shift) { names.append("shift") }
        if flags.contains(.command) { names.append("command") }
        return Shortcut(keyCode: UInt32(event.keyCode), modifiers: names)
    }

    /// Whether the Hyper key is on: ⌃⌥⌘ is then written ⇪, the key the owner holds.
    static var hyperOn = false

    /// "⌃⌥⌘L" ("⇪L" with the Hyper key); "None" for a command without shortcut.
    static func label(_ shortcut: Shortcut) -> String {
        guard let keyCode = shortcut.keyCode else { return "None" }
        let symbols = ["control": "⌃", "option": "⌥", "shift": "⇧", "command": "⌘"]
        var modifiers = shortcut.modifiers
        var prefix = ""
        if hyperOn, Set(modifiers).isSuperset(of: ["control", "option", "command"]) {
            prefix = "⇪"
            modifiers = modifiers.filter { $0 == "shift" }
        }
        return prefix + modifiers.compactMap { symbols[$0] }.joined() + keyName(keyCode)
    }

    static func label(of id: String, custom: [String: Shortcut]) -> String {
        effective(custom)[id].map(label) ?? ""
    }

    /// A menu item's title with the command's shortcut after it, or alone when it has none.
    static func menuTitle(_ title: String, id: String, custom: [String: Shortcut]) -> String {
        guard let shortcut = effective(custom)[id], shortcut.keyCode != nil else { return title }
        return "\(title)    \(label(shortcut))"
    }

    private static let keyNames: [Int: String] = [
        kVK_Space: "Space", kVK_Tab: "⇥", kVK_Return: "↩", kVK_Delete: "⌫", kVK_ForwardDelete: "⌦", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
        kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        // The digit keys by their digit: on an AZERTY keyboard they type & é " ' without Shift.
        kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3", kVK_ANSI_4: "4", kVK_ANSI_5: "5",
        kVK_ANSI_6: "6", kVK_ANSI_7: "7", kVK_ANSI_8: "8", kVK_ANSI_9: "9", kVK_ANSI_0: "0",
    ]

    private static func keyName(_ keyCode: UInt32) -> String {
        keyNames[Int(keyCode)] ?? Hotkeys.character(forKeyCode: keyCode) ?? "key \(keyCode)"
    }
}
