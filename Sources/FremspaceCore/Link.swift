import Foundation

/// What a `fremspace://` link asks for, so that another tool (a launcher, a button deck, a script)
/// can drive Fremspace: `fremspace://run/<command id>` runs a command of the shortcuts list,
/// `fremspace://desktop/<label>` shows the desktop of that name, `fremspace://scene/<name>` a scene.
public enum FremspaceLink: Equatable {
    case run(String)
    case desktop(String)
    case scene(String)
}

/// Whether `fremspace://run/<id>` may run that command. Any app, mail or chat message opens a link
/// without a prompt, and a web page after one: a link runs only what shows, goes to or resizes
/// something and is undone by a key. Left out on purpose: the slot swaps (they write the
/// configuration file), pause (the window manager would stop with no visible cause), the sends to a
/// drawer (the window in front would be parked off screen) and side by side (it presses a menu item
/// of another app). A command that is not listed here is refused: a new one has to be let in.
public func linkMayRun(_ id: String) -> Bool {
    if linkCommands.contains(id) { return true }
    let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
    guard parts.count == 2 else { return false }
    switch parts[0] {
    case "quick": return parts[1] == "restore" || QuickResize(rawValue: parts[1]) != nil
    case "scene": return Int(parts[1]).map { $0 >= 1 } ?? false
    default: return false
    }
}

private let linkCommands: Set<String> = [
    "palette", "openAdmin", "windowMenu", "reapply", "focusToggle",
    "slotLeft", "slotRight", "slotUp", "slotDown", "stackNext", "stackPrevious",
    "drawerLeft", "drawerRight",
]

public func parseLink(_ url: URL) -> FremspaceLink? {
    guard url.scheme?.lowercased() == "fremspace", let verb = url.host?.lowercased() else { return nil }
    let argument = url.pathComponents.filter { $0 != "/" }.joined(separator: "/")
    guard !argument.isEmpty else { return nil }
    switch verb {
    case "run": return .run(argument)
    case "desktop": return .desktop(argument)
    case "scene": return .scene(argument)
    default: return nil
    }
}
