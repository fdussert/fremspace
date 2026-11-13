import AppKit
import FremspaceCore
import SwiftUI

/// "Capture this desktop": the windows of the desktop shown on the selected display become the
/// selected desktop's layout, rounded to clean fractions. Unsaved until Save; Revert undoes it.
struct CaptureButton: View {
    @ObservedObject var session: EditSession

    var body: some View {
        Button { session.captureDesktop() } label: {
            // Windows on a screen, not a camera: nothing is photographed, and the previews are what
            // ask for Screen Recording.
            Label("Capture this desktop", systemImage: "macwindow.on.rectangle")
        }
        .help("Make this desktop's layout from the windows it shows now (Undo brings the previous one back)")
    }
}

extension EditSession {
    /// Makes the selected desktop's layout from the windows it shows now. Says in the status bar
    /// why not, when the display is away or shows another desktop.
    func captureDesktop() {
        guard let identity = selection.display,
              let display = connected.first(where: { $0.identity == identity }) else {
            status = Status(kind: .warning, text: "This display is not connected: there is nothing to capture.")
            return
        }
        let configurations = config.configurations
        guard configurations.indices.contains(selection.configuration),
              let real = engine.realDesktop(configuration: configurations[selection.configuration].id, display: identity,
                                            configured: selection.desktop),
              Spaces.current()[identity] == real else {
            status = Status(kind: .warning, text: "Show desktop \(selection.desktop + 1) on \(configuration?.displayName(identity) ?? identity.name) first, then capture.")
            return
        }
        let managed = Spaces.managed()
        let displays = connected
        let here = windows.windows(onScreen: true).filter {
            Spaces.spaceIndex(ofWindow: $0.info.id, managed: managed, displays: displays)
                == SpaceKey(display: identity, spaceIndex: real)
        }
        let order = AXWindows.onScreenWindowOrder()
        let sorted = here.sorted { (order.firstIndex(of: $0.info.id) ?? .max) < (order.firstIndex(of: $1.info.id) ?? .max) }
        let input = sorted.compactMap { w in windows.frame(w.element).map { (info: w.info, frame: $0) } }
        let layout = FremspaceCore.capture(windows: input, visible: display.visibleAX)
        guard !layout.slots.isEmpty else {
            status = Status(kind: .warning, text: "No window to capture on this desktop.")
            return
        }
        checkpoint()
        updateSpace { $0.layout = layout; $0.focusSlot = nil }
        selection.slot = layout.slots.first?.id
        status = Status(kind: .info, text: "Captured \(counted(layout.slots.count, "slot")). Check them, then save.")
    }
}
