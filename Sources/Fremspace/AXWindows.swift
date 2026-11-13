import AppKit
import ApplicationServices
import FremspaceCore

// Private SkyLight calls that bring one window of an app forward and make it key, without raising
// the app's other windows (alt-tab-macos technique; 19/20 in the Spaces spike, method B). SkyLight
// has no stub in the SDK, so they are looked up at run time; missing, `focus` activates the app.
private typealias SetFrontProcess = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UInt32, UInt32) -> CGError
private typealias PostEventRecord = @convention(c) (UnsafeMutablePointer<ProcessSerialNumber>, UnsafeMutablePointer<UInt8>) -> CGError
private let skyLight = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
private let setFrontProcess = dlsym(skyLight, "_SLPSSetFrontProcessWithOptions").map { unsafeBitCast($0, to: SetFrontProcess.self) }
private let postEventRecord = dlsym(skyLight, "SLPSPostEventRecordTo").map { unsafeBitCast($0, to: PostEventRecord.self) }
// Private: an AX element from a remote token, which reaches windows on desktops that are not shown
// (Accessibility lists only the current desktops' windows). alt-tab-macos technique, checked in the
// Spaces spike. Looked up at run time; missing, only the current desktops' windows are seen.
private typealias CreateWithRemoteToken = @convention(c) (CFData) -> Unmanaged<AXUIElement>?
private let hiServices = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices", RTLD_LAZY)
private let createWithRemoteToken = dlsym(hiServices, "_AXUIElementCreateWithRemoteToken")
    .map { unsafeBitCast($0, to: CreateWithRemoteToken.self) }

/// Reads and moves other apps' windows through Accessibility.
///
/// Every call here is synchronous and made on the main thread, where the hot keys and the key
/// filter of the Hyper key also run: an app that does not answer costs `messagingTimeout` per
/// call, and typing waits meanwhile. What bounds it today: the timeout itself, one question per
/// app before its windows are read (an app that hangs is then skipped for the pass), the scan
/// budget of `allWindows`, and the palette, which stops asking an app after its first timeout.
/// Moving the reads off the main thread would mean a placement pass in two steps (read, then
/// decide and move), for the engine, the drawers, the palette and the notch alike: a redesign of
/// its own, not done.
final class AXWindows {
    /// Every AX call to an app waits at most this long, so a hung app cannot freeze Fremspace.
    static let messagingTimeout: Float = 0.25

    /// Windows of every regular app, Fremspace excluded. Accessibility only lists windows on the
    /// current Space of each display; `onScreen` further keeps only those WindowServer shows.
    func windows(onScreen: Bool) -> [(info: WindowInfo, element: AXUIElement)] {
        let visible: Set<UInt32>? = onScreen ? Self.onScreenWindowIDs() : nil
        var result: [(info: WindowInfo, element: AXUIElement)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard app.processIdentifier != getpid(), let bundleID = app.bundleIdentifier else { continue }
            for element in windowElements(pid: app.processIdentifier) {
                guard let info = info(for: element, pid: app.processIdentifier, bundleID: bundleID) else { continue }
                if let visible, !visible.contains(info.id) { continue }
                result.append((info, element))
            }
        }
        return result
    }

    /// Every standard window of an app, those of desktops not shown included. Up to 1000 element ids
    /// per app, on the main thread: for startup, ⌃⌥⌘R and login only, and bounded: it stops once it
    /// found as many windows as the window list shows for the app, after `scanBudget`, or when the app
    /// stops answering.
    /// A known limit, not observed: an app that ran for days may have given its windows ids past
    /// 1000, and those on a desktop that is not shown are then missed until their desktop is.
    /// The bound stays: most apps own windows the window list counts and Accessibility never
    /// gives, so the scan runs to its end for them, and a longer one would cost its whole budget
    /// per app at every pass.
    static let scanBudget: TimeInterval = 0.3

    func allWindows(pid: pid_t) -> [AXUIElement] {
        var result = windowElements(pid: pid)
        var known = Set(result.compactMap(Self.windowID))
        guard let createWithRemoteToken else { return result }
        // Normal windows (layer 0) of the app on every desktop: an upper bound of what can be found.
        let listed = (CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []).filter {
            ($0[kCGWindowOwnerPID as String] as? Int32) == pid && ($0[kCGWindowLayer as String] as? Int) == 0
        }.count
        let deadline = Date().addingTimeInterval(Self.scanBudget)
        var token = Data(count: 20)
        token.replaceSubrange(0..<4, with: withUnsafeBytes(of: pid) { Data($0) })
        token.replaceSubrange(4..<8, with: withUnsafeBytes(of: Int32(0)) { Data($0) })
        token.replaceSubrange(8..<12, with: withUnsafeBytes(of: Int32(0x636f636f)) { Data($0) })
        for elementID in UInt64(0)..<1000 {
            if known.count >= listed || Date() > deadline { break }
            token.replaceSubrange(12..<20, with: withUnsafeBytes(of: elementID) { Data($0) })
            guard let element = createWithRemoteToken(token as CFData)?.takeRetainedValue() else { continue }
            AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
            let started = Date()
            let subrole = copy(element, kAXSubroleAttribute) as? String
            if Date().timeIntervalSince(started) > Double(Self.messagingTimeout) * 0.8 { break }
            guard subrole == kAXStandardWindowSubrole, let id = Self.windowID(element), known.insert(id).inserted else {
                continue
            }
            result.append(element)
        }
        if Date() > deadline {
            Log.engine.notice("pid \(pid): window scan stopped after \(Int(Self.scanBudget * 1000)) ms with \(known.count) of \(listed) windows")
        }
        return result
    }

    /// The element and info of one window of the current desktops, found by id (its owner from the
    /// window list).
    func window(id: UInt32) -> (info: WindowInfo, element: AXUIElement)? {
        guard let entry = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let pid = entry[kCGWindowOwnerPID as String] as? Int32,
              let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
              let element = windowElements(pid: pid).first(where: { Self.windowID($0) == id }),
              let info = info(for: element, pid: pid, bundleID: bundleID) else { return nil }
        return (info, element)
    }

    /// What an app answers when asked for its windows: `.success`, or why not (`.apiDisabled` when
    /// the Accessibility grant does not hold for this build, `.cannotComplete` for an app that hangs).
    func probe(pid: pid_t) -> AXError {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
    }

    func windowElements(pid: pid_t) -> [AXUIElement] {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return (copy(app, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// The app's windows, or nil when the app did not answer (busy, timed out): "no answer" must not
    /// be taken for "no window".
    func windowElementsIfAnswered(pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        return copy(app, kAXWindowsAttribute) as? [AXUIElement]
    }

    func info(for element: AXUIElement, pid: pid_t, bundleID: String) -> WindowInfo? {
        guard let id = Self.windowID(element) else { return nil }
        let title = (copy(element, kAXTitleAttribute) as? String) ?? ""
        var info = WindowInfo(
            id: id,
            pid: pid,
            bundleID: bundleID,
            title: title,
            profile: browserProfile(fromTitle: title, bundleID: bundleID),
            isStandard: (copy(element, kAXSubroleAttribute) as? String) == kAXStandardWindowSubrole,
            isMinimized: (copy(element, kAXMinimizedAttribute) as? Bool) ?? false,
            isFullScreen: (copy(element, "AXFullScreen") as? Bool) ?? false)
        if info.isStandard {
            var settable = DarwinBoolean(true)
            if AXUIElementIsAttributeSettable(element, kAXSizeAttribute as CFString, &settable) == .success {
                info.isFixedSize = !settable.boolValue
            }
        }
        if isTabbedBrowser(bundleID), info.isStandard {
            info.isPopup = !hasTabStrip(element, id: id)
        }
        return info
    }

    /// Tab-strip answers per window. A window just created may not have built its tab strip yet, so a
    /// "no" is only kept once the window is a second old.
    private var tabStrip: [UInt32: Bool] = [:]
    private var firstSeen: [UInt32: Date] = [:]

    private func hasTabStrip(_ window: AXUIElement, id: UInt32) -> Bool {
        if let known = tabStrip[id] { return known }
        let seen = firstSeen[id] ?? Date()
        firstSeen[id] = seen
        let found = contains(role: "AXTabGroup", in: window, depth: 9)
        if found || Date().timeIntervalSince(seen) > 1 { tabStrip[id] = found }
        return found
    }

    private func contains(role: String, in element: AXUIElement, depth: Int) -> Bool {
        guard depth > 0, let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return false }
        for child in children {
            if (copy(child, kAXRoleAttribute) as? String) == role { return true }
        }
        // The page itself (AXWebArea) can be huge and never holds the browser's tab strip.
        return children.contains {
            (copy($0, kAXRoleAttribute) as? String) != "AXWebArea" && contains(role: role, in: $0, depth: depth - 1)
        }
    }

    /// Whether the window holds an element with this DOM identifier (web-based apps such as Teams
    /// expose their page). Bounded: `budget` elements at most, so a huge page costs little.
    func containsDOMIdentifier(_ identifier: String, in window: AXUIElement, budget: Int = 800) -> Bool {
        var left = budget
        func search(_ element: AXUIElement, depth: Int) -> Bool {
            guard depth > 0, left > 0 else { return false }
            left -= 1
            if (copy(element, "AXDOMIdentifier") as? String) == identifier { return true }
            guard let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] else { return false }
            return children.contains { search($0, depth: depth - 1) }
        }
        return search(window, depth: 24)
    }

    /// Sends a window to native full screen.
    @discardableResult
    func enterFullScreen(_ window: AXUIElement) -> Bool {
        AXUIElementSetAttributeValue(window, "AXFullScreen" as CFString, kCFBooleanTrue) == .success
    }

    /// What recognises the window after a relaunch: tab titles of a tabbed browser (read from its
    /// tab strip), the document of other apps, the size. Slow on a browser with many tabs: called
    /// off the placement pass.
    func identity(of element: AXUIElement, info: WindowInfo) -> WindowIdentity {
        let browser = isTabbedBrowser(info.bundleID)
        // A browser's document is its active tab's URL: it changes with every tab, so it is not used.
        let document = browser ? nil : (copy(element, kAXDocumentAttribute) as? String)
        return WindowIdentity(bundleID: info.bundleID, profile: info.profile, document: document, title: info.title,
                              tabs: browser ? tabTitles(element) : [], size: frame(element)?.size ?? .zero)
    }

    /// The titles of the tabs in a browser window's tab strip.
    private func tabTitles(_ window: AXUIElement) -> [String] {
        var titles: [String] = []
        func walk(_ element: AXUIElement, depth: Int) {
            guard depth < 12 else { return }
            let role = copy(element, kAXRoleAttribute) as? String
            if role == "AXWebArea" { return }
            let children = copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
            if role == "AXTabGroup" {
                for tab in children where ["AXRadioButton", "AXTab"].contains(copy(tab, kAXRoleAttribute) as? String) {
                    let title = copy(tab, kAXTitleAttribute) as? String ?? ""
                    titles.append(title.isEmpty ? (copy(tab, kAXDescriptionAttribute) as? String ?? "") : title)
                }
                return
            }
            for child in children { walk(child, depth: depth + 1) }
        }
        walk(window, depth: 0)
        return titles
    }

    /// The CGWindowID of an AX window element, with `_AXUIElementGetWindow`: private but stable
    /// for a decade, and used by every macOS window manager. Nil too when this macOS no longer
    /// has it: no window is known then, and the engine says why it applies nothing.
    static func windowID(_ element: AXUIElement) -> UInt32? {
        var id: CGWindowID = 0
        guard let windowOfElement = PrivateCalls.windowOfElement, windowOfElement(element, &id) == .success,
              id != 0 else { return nil }
        return id
    }

    /// The window's frame in AX coordinates (top left of the primary display, y down).
    func frame(_ e: AXUIElement) -> CGRect? {
        guard let p = copy(e, kAXPositionAttribute), let s = copy(e, kAXSizeAttribute),
              CFGetTypeID(p) == AXValueGetTypeID(), CFGetTypeID(s) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, size = CGSize.zero
        guard AXValueGetValue(p as! AXValue, .cgPoint, &point),
              AXValueGetValue(s as! AXValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    /// Size, then position, then size again: a window crossing displays may be clamped to the
    /// old display's size by the first call, and the last one fixes it.
    /// Returns the first error (an app that is busy past the messaging timeout answers
    /// `.cannotComplete`), or `.success`. A size the app refuses is not an error: read it back.
    @discardableResult
    func setFrame(_ e: AXUIElement, _ r: CGRect) -> AXError {
        var size = r.size, origin = r.origin
        guard let sizeValue = AXValueCreate(.cgSize, &size), let originValue = AXValueCreate(.cgPoint, &origin) else {
            return .failure
        }
        let results = [
            AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sizeValue),
            AXUIElementSetAttributeValue(e, kAXPositionAttribute as CFString, originValue),
            AXUIElementSetAttributeValue(e, kAXSizeAttribute as CFString, sizeValue),
        ]
        return results.first { $0 != .success } ?? .success
    }

    func raise(_ e: AXUIElement) {
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
    }

    /// Brings `e` to the front with the keyboard: its app becomes frontmost, the window main and raised.
    /// Only this window comes forward: the app's other windows stay where they are in the stacking
    /// order (activating the app would raise them all, e.g. every Finder window when opening a
    /// drawer holding one). Falls back to activating the app if the private call fails.
    func focus(_ e: AXUIElement, pid: pid_t) {
        var psn = ProcessSerialNumber()
        if let setFrontProcess, let processForPID = PrivateCalls.processForPID, let id = Self.windowID(e),
           processForPID(pid, &psn) == noErr,
           setFrontProcess(&psn, id, Self.userGenerated) == .success {
            makeKey(&psn, id)
        } else if let app = NSRunningApplication(processIdentifier: pid) {
            if #available(macOS 14, *) { app.activate() } else { app.activate(options: []) }
        }
        AXUIElementSetAttributeValue(e, kAXMainAttribute as CFString, kCFBooleanTrue)
        AXUIElementPerformAction(e, kAXRaiseAction as CFString)
    }

    /// `kCPSUserGenerated`: front only the given window.
    private static let userGenerated: UInt32 = 0x200

    /// Posts the two event records that make `id` the key window of its process.
    private func makeKey(_ psn: inout ProcessSerialNumber, _ id: UInt32) {
        guard let postEventRecord else { return }
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: id) { for i in 0..<4 { bytes[0x3c + i] = $0[i] } }
        for i in 0x20..<0x30 { bytes[i] = 0xff }
        bytes[0x08] = 0x01
        _ = postEventRecord(&psn, &bytes)
        bytes[0x08] = 0x02
        _ = postEventRecord(&psn, &bytes)
    }

    /// The focused window of the frontmost app, if any.
    /// The focused window of the frontmost app. Read from the app that owns the menu bar first: while
    /// Fremspace's own menu is open, the system-wide focus is the menu, not the owner's window.
    func focusedWindow() -> AXUIElement? {
        if let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid() {
            let app = AXUIElementCreateApplication(front.processIdentifier)
            AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
            for attribute in [kAXFocusedWindowAttribute, kAXMainWindowAttribute] {
                if let window = copy(app, attribute), CFGetTypeID(window) == AXUIElementGetTypeID() {
                    return (window as! AXUIElement)
                }
            }
        }
        guard let app = copy(AXUIElementCreateSystemWide(), kAXFocusedApplicationAttribute) else { return nil }
        guard CFGetTypeID(app) == AXUIElementGetTypeID() else { return nil }
        guard let window = copy(app as! AXUIElement, kAXFocusedWindowAttribute),
              CFGetTypeID(window) == AXUIElementGetTypeID() else { return nil }
        return (window as! AXUIElement)
    }

    static func onScreenWindowIDs() -> Set<UInt32> {
        Set(onScreenWindowOrder())
    }

    /// On-screen window ids, front to back (the window server's order).
    static func onScreenWindowOrder() -> [UInt32] {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        return list.compactMap { ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value }
    }

    /// Presses the app's "New Window" menu item, found by its shortcut so that the language of the
    /// menus does not matter (see `newWindowItem`). Only the app's own menu and the two after it
    /// are read: a browser's History and Bookmarks menus hold hundreds of items. False when the
    /// app has no such item or does not answer.
    func pressNewWindow(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 1)
        guard let bar = copy(app, kAXMenuBarAttribute), CFGetTypeID(bar) == AXUIElementGetTypeID() else { return false }
        var items: [(element: AXUIElement, shortcut: MenuShortcut)] = []
        for title in children(bar as! AXUIElement).dropFirst().prefix(3) {
            for menu in children(title) {
                for item in children(menu) {
                    guard let key = copy(item, kAXMenuItemCmdCharAttribute) as? String, !key.isEmpty else { continue }
                    let modifiers = (copy(item, kAXMenuItemCmdModifiersAttribute) as? NSNumber)?.intValue ?? 0
                    items.append((item, MenuShortcut(title: copy(item, kAXTitleAttribute) as? String ?? "", key: key,
                                                     commandOnly: modifiers == 0)))
                }
            }
        }
        guard let index = newWindowItem(items.map(\.shortcut)) else { return false }
        return AXUIElementPerformAction(items[index].element, kAXPressAction as CFString) == .success
    }

    private func children(_ element: AXUIElement) -> [AXUIElement] {
        copy(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
    }

    private func copy(_ element: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }
}
