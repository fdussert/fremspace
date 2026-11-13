import AppKit

/// Shows a desktop that has no window to give the keyboard to. macOS has no call for "show this
/// desktop"; it shows the desktop of the window that takes the keyboard. So a window of Fremspace's
/// own, of one transparent point, is sent to the desktop and made key, then closed.
enum DesktopJump {
    private final class Helper: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    private static var helper: Helper?

    /// `completion(true)` once the display shows the desktop.
    static func show(spaceID sid: UInt64, on display: Displays.Connected, completion: ((Bool) -> Void)? = nil) {
        guard let primary = NSScreen.screens.first(where: { $0.frame.origin == .zero }) else {
            completion?(false)
            return
        }
        helper?.close()
        let centre = NSPoint(x: display.frameAX.midX, y: primary.frame.height - display.frameAX.midY)
        let window = Helper(contentRect: NSRect(origin: centre, size: NSSize(width: 1, height: 1)), styleMask: [.borderless],
                            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.orderFrontRegardless()
        helper = window
        let before = NSWorkspace.shared.frontmostApplication
        SpaceMover.send(UInt32(window.windowNumber), toSpace: sid) { arrived in
            guard arrived else {
                Log.app.error("desktop jump: the helper window did not reach space \(sid)")
                window.close()
                completion?(false)
                return
            }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                let shown = Spaces.managed().displays.first(where: { $0.uuid == display.uuid })?.current == sid
                window.close()
                if helper === window { helper = nil }
                // Fremspace has nothing to show there: the keyboard goes back to an app.
                if NSApp.isActive, NSApp.keyWindow == nil {
                    NSApp.hide(nil)
                    if !shown { before?.activate() }
                }
                Log.app.info("desktop jump to space \(sid): \(shown ? "shown" : "not shown", privacy: .public)")
                completion?(shown)
            }
        }
    }
}
