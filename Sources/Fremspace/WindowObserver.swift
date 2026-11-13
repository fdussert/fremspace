import AppKit
import ApplicationServices

enum WindowEvent {
    case created(UInt32)
    case destroyed(UInt32)
    case moved(UInt32)
    case resized(UInt32)
    case appLaunched(Int32)
    case appTerminated(Int32)
    case spaceChanged
    /// A window became the focused window of the active app (app activation, ⌘Tab, click).
    case activated(UInt32)
    /// A window's title changed (a Teams meeting window going from "Meeting join" to the call).
    case titleChanged(UInt32)
}

/// Turns Accessibility notifications and workspace notifications into `WindowEvent`s, on the main
/// thread. One `AXObserver` per running app: window creation is observed on the app element,
/// moves, resizes and destruction on each window.
final class WindowObserver {
    var onEvent: ((WindowEvent) -> Void)?

    private struct AppObservation {
        let observer: AXObserver
        let app: AXUIElement
        /// Whether window creation is observed; a freshly launched app may refuse at first.
        var watchesCreation: Bool
        /// Window elements already subscribed, with their id (a destroyed element can no longer
        /// tell its id).
        var windows: [AXUIElement: UInt32] = [:]
    }

    private var apps: [pid_t: AppObservation] = [:]
    private var tokens: [NSObjectProtocol] = []
    private let windowNotifications = [kAXWindowMovedNotification, kAXWindowResizedNotification,
                                       kAXUIElementDestroyedNotification, kAXTitleChangedNotification]

    func start() {
        let center = NSWorkspace.shared.notificationCenter
        tokens.append(center.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil,
                                         queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.onEvent?(.appLaunched(app.processIdentifier))
            self?.observe(app, announce: true)
            self?.catchUp(app.processIdentifier)
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil,
                                         queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            self?.stopObserving(app.processIdentifier)
            self?.onEvent?(.appTerminated(app.processIdentifier))
        })
        tokens.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil,
                                         queue: .main) { [weak self] note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  let observation = self?.apps[app.processIdentifier] else { return }
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(observation.app, kAXFocusedWindowAttribute as CFString, &value) == .success,
                  let window = value, CFGetTypeID(window) == AXUIElementGetTypeID(),
                  let id = AXWindows.windowID(window as! AXUIElement) else { return }
            self?.onEvent?(.activated(id))
        })
        tokens.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil,
                                         queue: .main) { [weak self] _ in
            guard let self else { return }
            for (pid, observation) in self.apps where !observation.watchesCreation { self.retryCreationWatch(pid) }
            self.subscribeAllWindows()
            self.onEvent?(.spaceChanged)
        })
        for app in NSWorkspace.shared.runningApplications {
            observe(app, announce: false)
        }
        // Apps that were busy (everything starts at once at login) get the same catch-up as a
        // launching app.
        for (pid, observation) in apps where !observation.watchesCreation { catchUp(pid) }
    }

    deinit {
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        for pid in Array(apps.keys) { stopObserving(pid) }
    }

    /// `announce`: report the windows found now as created (an app that just launched may already
    /// have its first window when the launch notification arrives).
    private func observe(_ app: NSRunningApplication, announce: Bool) {
        let pid = app.processIdentifier
        guard app.activationPolicy == .regular, pid != getpid(), apps[pid] == nil else { return }
        var created: AXObserver?
        guard AXObserverCreate(pid, axCallback, &created) == .success, let observer = created else {
            Log.windows.error("AXObserverCreate failed for pid \(pid)")
            return
        }
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, AXWindows.messagingTimeout)
        let added = AXObserverAddNotification(observer, element, kAXWindowCreatedNotification as CFString, refcon)
        AXObserverAddNotification(observer, element, kAXFocusedWindowChangedNotification as CFString, refcon)
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        apps[pid] = AppObservation(observer: observer, app: element, watchesCreation: added == .success)
        let found = subscribeWindows(of: pid)
        if announce {
            found.forEach { onEvent?(.created($0)) }
        }
    }

    /// A launching app can open its first window before its Accessibility side answers, so the
    /// creation notification is missed. Rescan it a few times while it settles, retrying the
    /// subscription and reporting windows that appeared unseen as created.
    private func catchUp(_ pid: pid_t) {
        for delay in [0.3, 1.0, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self, self.apps[pid] != nil else { return }
                self.retryCreationWatch(pid)
                for id in self.subscribeWindows(of: pid) {
                    self.onEvent?(.created(id))
                }
            }
        }
    }

    /// Subscribes again to window creation for an app that did not answer the first time (busy at
    /// launch or at login); its windows created meanwhile come through the next rescan.
    private func retryCreationWatch(_ pid: pid_t) {
        guard var observation = apps[pid], !observation.watchesCreation else { return }
        let added = AXObserverAddNotification(observation.observer, observation.app,
                                              kAXWindowCreatedNotification as CFString, refcon)
        observation.watchesCreation = added == .success
        if added == .success {
            AXObserverAddNotification(observation.observer, observation.app,
                                      kAXFocusedWindowChangedNotification as CFString, refcon)
            Log.windows.info("now watching window creation of pid \(pid)")
        }
        apps[pid] = observation
    }

        private func stopObserving(_ pid: pid_t) {
        guard let observation = apps.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observation.observer), .commonModes)
    }

    /// Accessibility only lists the windows of the current Space, so windows of other Spaces are
    /// subscribed when their Space comes up.
    private func subscribeAllWindows() {
        for pid in Array(apps.keys) { subscribeWindows(of: pid) }
    }

    /// Subscribes the app's windows on the current Space; returns the ids that were new.
    @discardableResult
    private func subscribeWindows(of pid: pid_t) -> [UInt32] {
        guard let observation = apps[pid] else { return [] }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(observation.app, kAXWindowsAttribute as CFString, &value) == .success,
              let windows = value as? [AXUIElement] else { return [] }
        return windows.compactMap { window in
            let known = apps[pid]?.windows[window] != nil
            let id = subscribe(window, pid: pid)
            return known ? nil : id
        }
    }

    /// Subscribes one window (idempotent); returns its id.
    @discardableResult
    private func subscribe(_ window: AXUIElement, pid: pid_t) -> UInt32? {
        guard var observation = apps[pid], let id = AXWindows.windowID(window) else { return nil }
        if observation.windows[window] != nil { return id }
        for name in windowNotifications {
            AXObserverAddNotification(observation.observer, window, name as CFString, refcon)
        }
        observation.windows[window] = id
        apps[pid] = observation
        return id
    }

    private var refcon: UnsafeMutableRawPointer {
        Unmanaged.passUnretained(self).toOpaque()
    }

    fileprivate func handle(_ element: AXUIElement, _ notification: String) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        switch notification {
        case kAXWindowCreatedNotification:
            let known = apps[pid]?.windows[element] != nil
            if let id = subscribe(element, pid: pid), !known { onEvent?(.created(id)) }
        case kAXUIElementDestroyedNotification:
            guard var observation = apps[pid], let id = observation.windows.removeValue(forKey: element) else { return }
            apps[pid] = observation
            onEvent?(.destroyed(id))
        case kAXWindowMovedNotification:
            if let id = AXWindows.windowID(element) { onEvent?(.moved(id)) }
        case kAXWindowResizedNotification:
            if let id = AXWindows.windowID(element) { onEvent?(.resized(id)) }
        case kAXTitleChangedNotification:
            if let id = AXWindows.windowID(element) { onEvent?(.titleChanged(id)) }
        case kAXFocusedWindowChangedNotification:
            // Only the active app's focus matters: a background app changing its own focused window
            // is not the user going to that window.
            guard NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
                  let id = AXWindows.windowID(element) else { return }
            onEvent?(.activated(id))
        default:
            break
        }
    }
}

private func axCallback(_ observer: AXObserver, _ element: AXUIElement, _ notification: CFString,
                        _ refcon: UnsafeMutableRawPointer?) {
    guard let refcon else { return }
    let windowObserver = Unmanaged<WindowObserver>.fromOpaque(refcon).takeUnretainedValue()
    windowObserver.handle(element, notification as String)
}
