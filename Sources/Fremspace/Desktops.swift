import AppKit
import ApplicationServices
import FremspaceCore

/// Desktop counts, and adding missing desktops by pressing Mission Control's "add desktop" button
/// through Accessibility (spike `docs/spikes/2026-11-add-desktop.md`: on macOS 27 Mission Control is
/// drawn by `WindowManager`; one `mc.display` group per display, its `mc.spaces.add` button adds a
/// desktop at the end). Fremspace never removes or reorders desktops.
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
        // `CoreDockSendNotification`, private but long-standing, asks the Dock to show Mission Control.
        guard let dockNotification = PrivateCalls.dockNotification else {
            Log.app.notice("add desktop: this macOS no longer has the call that opens Mission Control")
            return false
        }
        guard let wm = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.WindowManager").first else { return false }
        let app = AXUIElementCreateApplication(wm.processIdentifier)
        AXUIElementSetMessagingTimeout(app, 1)
        _ = dockNotification("com.apple.expose.awake" as CFString, 0)
        var opened = false
        // Escape only if Mission Control showed up: otherwise it would reach the user's app.
        defer { if opened { closeMissionControl() } }
        var bar: AXUIElement?
        for _ in 0..<20 where bar == nil {
            wait(0.1)
            let groups = children(app).filter { identifier($0) == "mc.display" }
            opened = opened || !groups.isEmpty
            let group = groups.first { frame($0).origin == display.frameAX.origin }
            bar = group.flatMap { children($0).first { identifier($0) == "mc.spaces" } }
        }
        guard let bar, let button = children(bar).first(where: { identifier($0) == "mc.spaces.add" }) else {
            Log.app.notice("add desktop: Mission Control's add button not found")
            return false
        }
        for _ in 0..<count {
            let before = Desktops.counts()[display.identity] ?? 0
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { return false }
            var added = false
            for _ in 0..<20 where !added {
                wait(0.05)
                added = (Desktops.counts()[display.identity] ?? 0) > before
            }
            guard added else { return false }
        }
        return true
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

    private static func frame(_ e: AXUIElement) -> CGRect {
        var p: CFTypeRef?, s: CFTypeRef?
        var point = CGPoint.zero, size = CGSize.zero
        if AXUIElementCopyAttributeValue(e, kAXPositionAttribute as CFString, &p) == .success { AXValueGetValue(p as! AXValue, .cgPoint, &point) }
        if AXUIElementCopyAttributeValue(e, kAXSizeAttribute as CFString, &s) == .success { AXValueGetValue(s as! AXValue, .cgSize, &size) }
        return CGRect(origin: point, size: size)
    }
}
