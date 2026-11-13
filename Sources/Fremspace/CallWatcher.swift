import AppKit
import ApplicationServices
import FremspaceCore

/// Sends call windows to native full screen when the call starts, for the apps turned on in the
/// general settings (`Config.fullScreenCalls`). A window is sent once: taken out of full screen by hand, it stays out.
final class CallWatcher {
    /// Whether calls of this app go to full screen now (false while paused or not running).
    var wants: (String) -> Bool = { _ in false }

    private let windows: AXWindows
    private var sent: Set<UInt32> = []
    private var pending: Set<UInt32> = []

    init(windows: AXWindows) {
        self.windows = windows
    }

    /// Something happened to this window (it appeared, its title changed, it came to the front):
    /// looks now and a little later, since the call controls come after the window and its title.
    func check(_ id: UInt32) {
        guard !sent.contains(id), !pending.contains(id) else { return }
        guard let (info, _) = windows.window(id: id), callWindowMarker(bundleID: info.bundleID) != nil,
              wants(info.bundleID) else { return }
        pending.insert(id)
        let delays = [0.2, 1.0, 2.5, 5.0]
        for (index, delay) in delays.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pending.contains(id) else { return }
                if self.look(id) || index == delays.count - 1 { self.pending.remove(id) }
            }
        }
    }

    func forget(_ id: UInt32) {
        sent.remove(id)
        pending.remove(id)
    }

    /// True when the window was dealt with (sent, or already full screen).
    private func look(_ id: UInt32) -> Bool {
        guard let (info, element) = windows.window(id: id), let marker = callWindowMarker(bundleID: info.bundleID),
              wants(info.bundleID) else { return false }
        // The small call monitor and the sharing toolbar are not standard resizable windows.
        guard info.isStandard, !info.isFixedSize, !info.isMinimized else { return false }
        if info.isFullScreen {
            sent.insert(id)
            return true
        }
        // Never under a drag.
        guard NSEvent.pressedMouseButtons & 1 == 0 else { return false }
        switch marker {
        case .control(let identifier):
            guard windows.containsDOMIdentifier(identifier, in: element) else { return false }
        case .titlePrefix:
            guard isCallWindow(title: info.title, marker: marker) == true else { return false }
        }
        sent.insert(id)
        let done = windows.enterFullScreen(element)
        Log.windows.info("call window \(id) of \(info.bundleID, privacy: .public): full screen \(done ? "asked" : "refused")")
        return true
    }
}
