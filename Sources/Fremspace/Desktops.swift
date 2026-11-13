import AppKit
import ApplicationServices
import FremspaceCore

/// Desktop counts, and adding or removing desktops through Mission Control's own buttons, pressed
/// with Accessibility (spike `docs/spikes/2026-11-add-desktop.md`: on macOS 27 Mission Control is
/// drawn by `WindowManager`; one `mc.display` group per display, whose Spaces bar holds a button per
/// Space and the `mc.spaces.add` button). Fremspace adds what the configuration lacks and removes
/// only a desktop the owner asked to remove; it never reorders desktops.
enum Desktops {
    /// Desktops (full-screen Spaces not counted) per connected display.
    static func counts() -> [DisplayIdentity: Int] {
        let byUUID = Dictionary(Displays.connected().map { ($0.uuid, $0.identity) }, uniquingKeysWith: { a, _ in a })
        var result: [DisplayIdentity: Int] = [:]
        for display in Spaces.managed().displays {
            if let identity = byUUID[display.uuid] { result[identity] = display.desktops.count }
        }
        return result
    }

    /// Adds `count` desktops at the end of `display`'s list. Opens Mission Control, presses its add
    /// button, closes it. False when Mission Control or the button cannot be found, or a press did
    /// not add a desktop; desktops added before the failure stay.
    static func add(on display: Displays.Connected, count: Int) -> Bool {
        guard count > 0 else { return true }
        return inSpacesBar(of: display, for: "add desktop") { bar in
            guard let button = children(bar).first(where: { identifier($0) == "mc.spaces.add" }) else {
                Log.app.notice("add desktop: Mission Control's add button not found")
                return false
            }
            for _ in 0..<count {
                let before = Desktops.counts()[display.identity] ?? 0
                guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
                guard changed(from: before, on: display, tries: 20) else { return false }
            }
            return true
        }
    }

    /// Removes the desktop at `position` (among the desktops of `display`, in Mission Control
    /// order) with the action its button carries there, the one behind the ✕ a person clicks. macOS
    /// sends its windows to another desktop, and nothing brings it back: the caller asked the
    /// owner. False, and nothing removed, when the button cannot be told for sure.
    static func remove(on display: Displays.Connected, position: Int) -> Bool {
        let before = Desktops.counts()[display.identity] ?? 0
        // macOS keeps one desktop per display.
        guard before > 1, (0..<before).contains(position) else { return false }
        return inSpacesBar(of: display, for: "remove desktop") { bar in
            guard let list = children(bar).first(where: { identifier($0) == "mc.spaces.list" }) else {
                Log.app.notice("remove desktop: Mission Control's list of Spaces not found")
                return false
            }
            // Full-screen Spaces sit in the same list and cannot be removed: only desktops carry
            // the action, in the order macOS lists them.
            let desktops = children(list).filter { actions($0).contains(removeAction) }
            // The wrong desktop gone cannot be put back. So the bar must show the desktops macOS
            // lists, and the button must be numbered like the one asked for ("Desktop 4").
            guard desktops.count == before,
                  desktopNumber(inTitle: title(desktops[position])) == position + 1 else {
                Log.app.notice("remove desktop: Mission Control does not show desktop \(position + 1, privacy: .public) where it is expected; nothing removed")
                return false
            }
            guard AXUIElementPerformAction(desktops[position], removeAction as CFString) == .success else { return false }
            return changed(from: before, on: display, tries: 40)
        }
    }

    private static let removeAction = "AXRemoveDesktop"

    /// Waits for the number of desktops of `display` to be another than `before`.
    private static func changed(from before: Int, on display: Displays.Connected, tries: Int) -> Bool {
        for _ in 0..<tries {
            wait(0.05)
            if (Desktops.counts()[display.identity] ?? before) != before { return true }
        }
        return false
    }

    /// Opens Mission Control, hands `body` the Spaces bar of `display`, then closes it. False when
    /// Mission Control or the bar cannot be found, or when `body` says so.
    private static func inSpacesBar(of display: Displays.Connected, for what: String, _ body: (AXUIElement) -> Bool) -> Bool {
        // `CoreDockSendNotification`, private but long-standing, asks the Dock to show Mission Control.
        guard let dockNotification = PrivateCalls.dockNotification else {
            Log.app.notice("\(what, privacy: .public): this macOS no longer has the call that opens Mission Control")
            return false
        }
        guard let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else { return false }
        let app = AXUIElementCreateApplication(wm.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        func isOpen() -> Bool { children(app).contains { identifier($0) == "mc.display" } }
        // The notification toggles Mission Control: sent while it is open, it would close it, and
        // nothing would be done.
        var opened = isOpen()
        if !opened { _ = dockNotification("com.apple.expose.awake" as CFString, 0) }
        // Escape only if Mission Control showed up and is still there: otherwise it would reach
        // the user's app.
        defer { if opened, isOpen() { closeMissionControl() } }
        var bar: AXUIElement?
        for _ in 0..<20 where bar == nil {
            wait(0.1)
            let groups = children(app).filter { identifier($0) == "mc.display" }
            opened = opened || !groups.isEmpty
            let group = groups.first { frame($0).origin == display.frameAX.origin }
            bar = group.flatMap { children($0).first { identifier($0) == "mc.spaces" } }
        }
        guard let bar else {
            Log.app.notice("\(what, privacy: .public): Mission Control's Spaces bar not found")
            return false
        }
        return body(bar)
    }

    private static func closeMissionControl() {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }

    private static func wait(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func children(_ e: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &value) == .success else { return [] }
        return (value as? [AXUIElement]) ?? []
    }

    private static func identifier(_ e: AXUIElement) -> String {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(e, "AXIdentifier" as CFString, &value)
        return (value as? String) ?? ""
    }

    private static func actions(_ e: AXUIElement) -> [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(e, &names) == .success else { return [] }
        return (names as? [String]) ?? []
    }

    /// What the button says: its title, or its description when it has no title.
    private static func title(_ e: AXUIElement) -> String {
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute] {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(e, attribute as CFString, &value)
            if let text = value as? String, !text.isEmpty { return text }
        }
        return ""
    }

    private static func frame(_ e: AXUIElement) -> CGRect {
        var p: CFTypeRef?, s: CFTypeRef?
        var point = CGPoint.zero, size = CGSize.zero
        if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success { AXValueGetValue(p as! AXValue, .cgPoint, &point) }
        if AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGRect(origin: point, size: size)
    }
}
