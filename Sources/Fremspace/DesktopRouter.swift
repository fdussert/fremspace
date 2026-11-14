import AppKit
import FremspaceCore

/// Sends windows to the desktop they belong on (spec Part A): new windows, every window at startup,
/// ⌃⌥⌘R and login, windows moved by hand out of a locked slot, and "Send to desktop". The decisions
/// are `route` (Core); this class reads the world, sends windows with `SpaceMover`, and tells the
/// engine where each one arrives. Owned by `Engine`, main thread.
final class DesktopRouter {
    /// Where a sent window goes once its desktop is shown: its slot (the engine places it) or a frame.
    struct Arrival {
        var desktop: ConfiguredDesktop
        var slotID: String?
        /// The remembered frame when it had no slot there.
        var frame: CGRect?
        /// Arriving from another display, it lands mostly off screen: it needs a frame.
        var crossDisplay: Bool
    }

    /// `FREMSPACE_DRY_RUN=1`: log where windows would be sent, send nothing (checking a new build on
    /// the owner's desktop).
    static let dryRun = ProcessInfo.processInfo.environment["FREMSPACE_DRY_RUN"] == "1"

    /// How long a new window is left to settle (title, profile, tab strip) before it is routed.
    static let appearDelay: TimeInterval = 1

    private unowned let engine: Engine
    private let windows: AXWindows

    private(set) var pendingArrival: [UInt32: Arrival] = [:]
    /// Windows a command sent somewhere: their lock does not pull them back (until they close).
    private var sentByCommand: Set<UInt32> = []
    /// The windows Fremspace itself asked an app for, and those that came: they stay where they
    /// opened (see `AskedWindows`).
    private var asked = AskedWindows()
    private var askedFor: Set<UInt32> = []
    /// Windows being sent now: their desktop change is not a hand move.
    private var inFlight: Set<UInt32> = []
    /// The configured desktop each known window was last seen on, and what it is.
    private var lastDesktop: [UInt32: ConfiguredDesktop] = [:]
    private var lastInfo: [UInt32: WindowInfo] = [:]
    /// The slot the engine last gave each window, and on which desktop: a hand move is judged on
    /// the slot the window left (the engine may have dropped its placement by then).
    private var lastSlot: [UInt32: (desktop: ConfiguredDesktop, slotID: String)] = [:]
    /// The remembered placement recognised for each live window.
    private var matched: [UInt32: RememberedPlacement] = [:]
    /// Windows on a layout desktop that are not the router's to move (dialogs, popups).
    private var notRoutable: Set<UInt32> = []
    private var dragCheckPending = false
    /// How long after a drop macOS takes to give the window its new desktop.
    static let dropDelay: TimeInterval = 0.3
    /// Until then, new windows are routed as restored ones (login, "Restore everything now").
    private var restoringUntil: Date?

    func restoring(until date: Date) {
        restoringUntil = date
    }

    private var isRestoring: Bool { restoringUntil.map { Date() < $0 } ?? false }

    /// Windows compared with the remembered windows of their app: only those are recorded where they
    /// are (see `Remembered.mayRecord`).
    private var recognised: Set<UInt32> = []

    func isRecognised(_ id: UInt32) -> Bool { recognised.contains(id) && !stillUnknown.contains(id) }

    /// Windows compared during a login that matched no remembered window yet. At a login a browser
    /// shows its windows before their tabs and titles can be read, and one comparison, a second
    /// after the window appeared, found nothing: the window stayed on the desktop where its app
    /// had put it and was recorded there, over the place it had (owner, 2026-11-14: three browser
    /// windows on the free desktop after a restart of the Mac). They are compared again
    /// (`compareAgainLater`) and are not recorded where they sit meanwhile.
    private var stillUnknown: Set<UInt32> = []
    /// How long to wait before each new comparison; after the last one the window is a new one.
    static let recognitionRetries: [TimeInterval] = [3, 8, 20, 40]

    private func compareAgainLater(_ id: UInt32, after delays: [TimeInterval] = DesktopRouter.recognitionRetries) {
        guard let delay = delays.first else {
            // Not a window Fremspace knew: it is recorded where it is from the next pass.
            stillUnknown.remove(id)
            engine.scheduleApplyFromRouter()
            return
        }
        stillUnknown.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.stillUnknown.contains(id) else { return }
            guard self.engine.mayRoute, self.matched[id] == nil, !self.inFlight.contains(id),
                  let (info, element) = self.windows.window(id: id), !self.engine.drawers.isMember(id) else {
                self.stillUnknown.remove(id)
                return
            }
            // Read again: what was read when the window appeared is what failed.
            let identity = self.engine.freshIdentity(of: element, info: info)
            guard let entry = self.recognise([id: identity])[id] else {
                return self.compareAgainLater(id, after: Array(delays.dropFirst()))
            }
            self.stillUnknown.remove(id)
            Log.engine.notice("window \(id) \(info.bundleID, privacy: .public) recognised on a later look: it goes where it was remembered")
            self.decide(info, reason: .login, entry: entry)
            self.engine.scheduleApplyFromRouter()
        }
    }

    /// The configuration or the desktop map changed: what is known per configured desktop no longer
    /// holds. Re-learned from the next pass, so nothing looks moved by hand.
    /// The apps a save just gave a slot to (`appsGivenASlot`): at the sort that follows the save,
    /// their windows on a free desktop go to the slot. Emptied by that sort.
    var givenASlot: Set<String> = []

    func reset() {
        lastDesktop.removeAll()
        lastSlot.removeAll()
        matched.removeAll()
    }

    /// The engine put this window in this slot of this configured desktop (a placement pass).
    func placed(_ id: UInt32, in slotID: String, on desktop: ConfiguredDesktop) {
        lastSlot[id] = (desktop, slotID)
    }

    /// When the ids of the windows alive now began: the later of the boot and of the owner's
    /// login. Window ids and process ids start again at boot, and a login ends every window of
    /// the session before it: what was saved or remembered before names other windows now.
    static let windowIDsSince: Date = max(systemBootTime(), consoleLoginTime() ?? .distantPast)

    /// `windowIDsSince`: window ids remembered before it belong to other windows now.
    let bootTime: Date

    init(engine: Engine, windows: AXWindows) {
        self.engine = engine
        self.windows = windows
        bootTime = Self.windowIDsSince
    }

    // MARK: - What the engine asks

    /// The remembered slot of a window on `desktop`, which wins over the first matching slot (so
    /// several windows of one app and profile each take their own slot).
    func rememberedSlot(_ id: UInt32, on desktop: ConfiguredDesktop) -> String? {
        let entry = matched[id]
            ?? engine.state.remembered.entry(forWindow: id, configurationID: engine.activeConfigurationID, idsSince: bootTime)
        guard let entry, entry.configurationID == engine.activeConfigurationID, entry.desktop == desktop else { return nil }
        return entry.slotID
    }

    /// The title the window had when it was last seen.
    func lastTitle(_ id: UInt32) -> String? { lastInfo[id]?.title }

    /// The engine saw this window on this configured desktop (a placement pass).
    func saw(_ info: WindowInfo, on desktop: ConfiguredDesktop) {
        lastInfo[info.id] = info
        if lastDesktop[info.id] == nil { lastDesktop[info.id] = desktop }
    }

    /// The window reached its desktop and was placed (or needs no frame).
    func arrived(_ id: UInt32) {
        pendingArrival[id] = nil
    }

    func forgetApp(_ pid: Int32) {
        for (id, info) in lastInfo where info.pid == pid { forget(id) }
    }

    func forget(_ id: UInt32) {
        pendingArrival[id] = nil
        sentByCommand.remove(id)
        askedFor.remove(id)
        inFlight.remove(id)
        lastDesktop[id] = nil
        lastSlot[id] = nil
        lastInfo[id] = nil
        matched[id] = nil
        recognised.remove(id)
        stillUnknown.remove(id)
        notRoutable.remove(id)
    }

    // MARK: - New windows

    /// A window Fremspace brought to the desktop shown because the owner asked for what it shows:
    /// it stays there, like the new window that would have opened.
    func keepHere(_ id: UInt32) {
        askedFor.insert(id)
        sentByCommand.insert(id)
    }

    /// Fremspace is about to ask the app `bundleID` for a window (a folder in the Finder, a file in
    /// its editor): the app's next new window stays on the desktop where it opens.
    func expectWindow(of bundleID: String) {
        let pids = Set(NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).map(\.processIdentifier))
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        let existing = list.compactMap { window -> UInt32? in
            guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pids.contains(pid) else { return nil }
            return (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        asked.expect(bundleID, existing: Set(existing), now: Date())
    }

    /// A window appeared: once it settles (and the mouse button is up), it goes to its desktop when
    /// it has none here.
    func handleAppeared(_ id: UInt32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.appearDelay) { [weak self] in
            self?.whenMouseUp { self?.routeAppeared(id) }
        }
    }

    /// An app launched: its windows are routed like new ones.
    func handleLaunched(_ pid: Int32) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.appearDelay) { [weak self] in
            guard let self else { return }
            for element in self.windows.windowElements(pid: pid) {
                if let id = AXWindows.windowID(element) { self.whenMouseUp { self.routeAppeared(id) } }
            }
        }
    }

    /// Windows the router looks at: those that can take a slot and, with "no floating windows",
    /// fixed-size ones too.
    private func mayRoute(_ info: WindowInfo) -> Bool {
        info.isManageable || (engine.noFloating && info.canChangeDesktop)
    }

    private func routeAppeared(_ id: UInt32) {
        guard engine.mayRoute, pendingArrival[id] == nil, !inFlight.contains(id),
              let (info, element) = windows.window(id: id), mayRoute(info), !engine.drawers.isMember(id) else { return }
        let identity = engine.identity(of: element, info: info)
        let entry = recognise([id: identity])[id]
        // The owner just opened it (its app is frontmost): the view follows it to its desktop. A window
        // that appears in the background goes without changing what the displays show.
        if isRestoring {
            if entry == nil { compareAgainLater(id) }
            decide(info, reason: .login, entry: entry)
            engine.scheduleApplyFromRouter()
            return
        }
        let frontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == info.pid
        decide(info, reason: .appeared, entry: entry, follow: frontmost ? element : nil)
        // Recognised: a window that stays is recorded where it is on the next pass.
        engine.scheduleApplyFromRouter()
    }

    // MARK: - Every window

    /// Every window of the apps with a slot or a remembered place, on every desktop: startup,
    /// ⌃⌥⌘R and login.
    func sortAll(reason: RouteReason) {
        guard engine.mayRoute, let configuration = engine.activeConfiguration else { return }
        let started = Date()
        var apps = Set(configuration.displays.flatMap { $0.spaces.flatMap { $0.layout?.slots.flatMap { $0.rules.map(\.bundleID) } ?? [] } })
        apps.formUnion(engine.state.remembered.entries.filter { $0.configurationID == configuration.id }
            .map(\.identity.bundleID))
        if engine.noFloating {
            // Also the apps without a slot that have a window on a desktop with a layout.
            apps.formUnion(appsOnLayoutDesktops(configuration))
        }
        var found: [(info: WindowInfo, element: AXUIElement)] = []
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            guard let bundleID = app.bundleIdentifier, apps.contains(bundleID), app.processIdentifier != getpid() else { continue }
            for element in windows.allWindows(pid: app.processIdentifier) {
                guard let info = windows.info(for: element, pid: app.processIdentifier, bundleID: bundleID),
                      mayRoute(info), !engine.drawers.isMember(info.id) else { continue }
                found.append((info, element))
            }
        }
        var identities: [UInt32: WindowIdentity] = [:]
        for (info, element) in found { identities[info.id] = engine.identity(of: element, info: info) }
        let entries = recognise(identities)
        var sent = 0
        if reason == .login {
            for (info, _) in found where entries[info.id] == nil { compareAgainLater(info.id) }
        }
        for (info, _) in found where decide(info, reason: reason, entry: entries[info.id]) { sent += 1 }
        if reason == .reapply { givenASlot = [] }
        engine.scheduleApplyFromRouter()
        Log.engine.notice("sorted \(found.count) windows (\(String(describing: reason), privacy: .public)): \(sent) sent, \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        if found.isEmpty {
            // Not one window of the configured apps: say what Accessibility answers, so that a grant
            // that no longer holds is not taken for an empty desk.
            let answers = NSWorkspace.shared.runningApplications
                .filter { $0.activationPolicy == .regular && $0.bundleIdentifier.map(apps.contains) == true }.prefix(3)
                .map { "\($0.bundleIdentifier ?? "?") \(windows.probe(pid: $0.processIdentifier).rawValue)" }
            Log.engine.error("no window found; Accessibility trusted: \(AXIsProcessTrusted()), answers: \(answers.joined(separator: ", "), privacy: .public)")
        }
    }

    /// The apps owning a normal window on a desktop with a layout (window list, no Accessibility: the
    /// windows of every app on every desktop would take too long to read).
    private func appsOnLayoutDesktops(_ configuration: Configuration) -> Set<String> {
        let managed = Spaces.managed()
        let displays = Displays.connected()
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var pids: Set<pid_t> = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, !pids.contains(pid),
                  let space = Spaces.spaceIndex(ofWindow: id, managed: managed, displays: displays),
                  let desktop = engine.configuredDesktop(space),
                  let display = displaySpec(for: desktop.display, in: configuration),
                  display.spaces.indices.contains(desktop.index), display.spaces[desktop.index].layout != nil else { continue }
            pids.insert(pid)
        }
        return Set(pids.compactMap { NSRunningApplication(processIdentifier: $0)?.bundleIdentifier })
    }

    /// The remembered placement of each live window: by window id, else by identity among the
    /// entries no live window claims. Entries recognised by identity take the new window id.
    private func recognise(_ live: [UInt32: WindowIdentity]) -> [UInt32: RememberedPlacement] {
        guard let configurationID = engine.activeConfigurationID else { return [:] }
        // Entries of other live windows (seen since the boot: older ids belong to other windows).
        let claimed = Set(lastDesktop.keys).union(matched.keys).subtracting(live.keys)
        let free = Remembered(entries: engine.state.remembered.entries.filter {
            !(claimed.contains($0.windowID) && $0.lastSeen >= bootTime)
        })
        let result = free.match(live: live, configurationID: configurationID, idsSince: bootTime)
        recognised.formUnion(live.keys)
        for (id, entry) in result {
            matched[id] = entry
            if entry.windowID != id {
                engine.adoptRemembered(entry, as: id)
                Log.engine.info("window \(id) \(entry.identity.bundleID, privacy: .public) recognised as remembered window \(entry.windowID)")
            }
        }
        return result
    }

    // MARK: - Hand moves

    /// Windows whose desktop changed without Fremspace sending them: a locked one goes back, the
    /// others stay and their new place is remembered.
    func checkHandMoves() {
        // Nothing moves under a held mouse button (a window dragged across desktops).
        whenMouseUp { [weak self] in self?.checkHandMovesNow() }
    }

    /// A window is being dragged: it may be dropped on another display. Checked once, shortly after
    /// the button is released (macOS gives the window its new desktop then).
    func checkHandMovesAfterDrag() {
        guard !dragCheckPending, NSEvent.pressedMouseButtons & 1 != 0 else { return }
        dragCheckPending = true
        whenMouseUp { [weak self] in
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.dropDelay) {
                self?.dragCheckPending = false
                self?.checkHandMoves()
            }
        }
    }

    private func checkHandMovesNow() {
        guard engine.mayRoute, let configuration = engine.activeConfiguration else { return }
        let managed = Spaces.managed()
        let displays = Displays.connected()
        if engine.noFloating { routeUnknown(configuration, managed: managed, displays: displays) }
        // A drawer member changes desktop with its display's drawer, not by the owner's hand.
        for (id, from) in lastDesktop where !inFlight.contains(id) && !engine.drawers.isMember(id) {
            guard let space = Spaces.spaceIndex(ofWindow: id, managed: managed, displays: displays),
                  let here = engine.configuredDesktop(space), here != from, let info = lastInfo[id] else { continue }
            lastDesktop[id] = here
            let remembered = matched[id]?.desktop
                ?? engine.state.remembered.entry(forWindow: id, configurationID: configuration.id, idsSince: bootTime)?.desktop
            let held = lastSlot[id].flatMap { $0.desktop == from ? $0.slotID : nil }
            switch route(window: info, on: here, reason: .handMoved(from: from), configuration: configuration,
                         remembered: remembered, heldSlot: held, sentByCommand: sentByCommand.contains(id),
                         noFloating: engine.noFloating, floatingApps: engine.floatingApps,
                         available: engine.availableDesktops) {
            case .send(let target):
                Log.engine.info("window \(id) \(info.bundleID, privacy: .public) moved by hand to a desktop that does not keep it (a locked slot elsewhere, or no floating); sending it to desktop \(target.index + 1) of \(target.display.name, privacy: .public)")
                send(info, to: target, entry: matched[id], byCommand: false)
            case .stay:
                // Deliberate: remembered there, like a command.
                sentByCommand.remove(id)
                engine.rememberDesktop(info, on: here, frame: Self.windowListFrame(id))
                matched[id] = engine.state.remembered.entry(forWindow: id, configurationID: configuration.id, idsSince: bootTime)
            }
        }
    }

    /// With "no floating windows": the windows the router never looked at (they sat on a free desktop
    /// when Fremspace started) that are now on a shown desktop with a layout are routed like new ones,
    /// without the view following them.
    private func routeUnknown(_ configuration: Configuration, managed: ManagedSpaces, displays: [Displays.Connected]) {
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(),
                  lastDesktop[id] == nil, !notRoutable.contains(id), !inFlight.contains(id), pendingArrival[id] == nil,
                  !engine.drawers.isMember(id),
                  let space = Spaces.spaceIndex(ofWindow: id, managed: managed, displays: displays),
                  let desktop = engine.configuredDesktop(space),
                  let display = displaySpec(for: desktop.display, in: configuration),
                  display.spaces.indices.contains(desktop.index), display.spaces[desktop.index].layout != nil else { continue }
            guard let (info, element) = windows.window(id: id), mayRoute(info) else {
                // A dialog, a popup, a panel: not looked up again.
                notRoutable.insert(id)
                continue
            }
            let entry = recognise([id: engine.identity(of: element, info: info)])[id]
            decide(info, reason: .appeared, entry: entry)
        }
    }

    // MARK: - Sending

    /// "Send to desktop": the owner's will, so the window's lock does not pull it back and it is
    /// remembered there.
    func send(_ id: UInt32, to desktop: ConfiguredDesktop, byCommand: Bool) {
        guard let info = windows.window(id: id)?.info ?? lastInfo[id] else { return }
        if byCommand { sentByCommand.insert(id) }
        send(info, to: desktop, entry: matched[id], byCommand: byCommand)
    }

    /// Routes one window; true when it is being sent.
    @discardableResult
    private func decide(_ info: WindowInfo, reason: RouteReason, entry: RememberedPlacement?,
                        follow: AXUIElement? = nil) -> Bool {
        guard let configuration = engine.activeConfiguration else { return false }
        let space = Spaces.spaceIndex(ofWindow: info.id)
        let here = space.flatMap { engine.configuredDesktop($0) }
        lastInfo[info.id] = info
        if let here { lastDesktop[info.id] = here }
        if asked.take(info.id, bundleID: info.bundleID, now: Date()) {
            askedFor.insert(info.id)
            // Like a window a command sent: nothing pulls it away later either.
            sentByCommand.insert(info.id)
            Log.engine.info("window \(info.id) \(info.bundleID, privacy: .public) was asked for by Fremspace: it stays where it opened")
        }
        // Wherever its app has a slot: the owner asked for this window here, now.
        if askedFor.contains(info.id), reason == .appeared { return false }
        // A window a drawer of its display takes is not sent anywhere: with "no floating windows" it
        // has no slot in the layouts, and a sort that ran before it joined its drawer sent it to the
        // free desktop (owner, 2026-11-14: the three windows of the drawers, at a start of Fremspace).
        if engine.drawerSlot(for: info) != nil { return false }
        let decision = route(window: info, on: here, reason: reason, configuration: configuration,
                             remembered: entry?.desktop, rememberedDeliberately: entry?.slotID == nil,
                             sentByCommand: sentByCommand.contains(info.id),
                             onIgnoredDisplay: space.map { key in
                                 configuration.displays.contains { $0.identity == key.display && $0.ignored }
                             } ?? false,
                             noFloating: engine.noFloating, floatingApps: engine.floatingApps,
                             givenASlot: reason == .reapply && givenASlot.contains(info.bundleID),
                             available: engine.availableDesktops)
        guard case .send(let target) = decision else { return false }
        send(info, to: target, entry: entry, byCommand: false, follow: follow)
        return true
    }

    /// `follow`: once sent, the window gets the keyboard, which shows its desktop.
    private func send(_ info: WindowInfo, to target: ConfiguredDesktop, entry: RememberedPlacement?, byCommand: Bool,
                      follow: AXUIElement? = nil) {
        let id = info.id
        guard engine.canMoveBetweenDesktops || byCommand else {
            Log.engine.notice("window \(id) \(info.bundleID, privacy: .public) belongs on another desktop, but moving windows between desktops is unavailable")
            return
        }
        guard let real = engine.realSpace(target), let sid = Spaces.spaceID(display: real.display, real: real.spaceIndex) else {
            return
        }
        if Self.dryRun {
            // No title: a window's title never goes to the log.
            Log.engine.notice("dry run: would send window \(id) \(info.bundleID, privacy: .public) to desktop \(target.index + 1) of \(target.display.name, privacy: .public)")
            return
        }
        let from = Spaces.spaceIndex(ofWindow: id)
        let onTarget = entry?.desktop == target
        let arrival = Arrival(desktop: target, slotID: onTarget ? entry?.slotID : nil,
                              frame: onTarget && entry?.slotID == nil ? entry?.frame : nil,
                              crossDisplay: from?.display != target.display)
        inFlight.insert(id)
        let started = Date()
        SpaceMover.send(id, toSpace: sid) { [weak self] arrived in
            guard let self else { return }
            self.inFlight.remove(id)
            // A window that closed on the way (a splash screen) says nothing about the mover.
            if arrived || !Spaces.spaceIDs(ofWindow: id).isEmpty { self.engine.recordSend(success: arrived) }
            guard arrived else {
                Log.engine.error("window \(id) \(info.bundleID, privacy: .public) could not be sent to desktop \(target.index + 1) of \(target.display.name, privacy: .public)")
                return
            }
            Log.engine.info("window \(id) \(info.bundleID, privacy: .public) sent to desktop \(target.index + 1) of \(target.display.name, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            self.lastDesktop[id] = target
            self.pendingArrival[id] = arrival
            if byCommand {
                self.engine.rememberDesktop(info, on: target, frame: arrival.frame ?? Self.windowListFrame(id))
                self.matched[id] = self.engine.state.remembered.entry(forWindow: id, configurationID: self.engine.activeConfigurationID,
                                                                      idsSince: self.bootTime)
            }
            self.engine.windowSent(id)
            if let follow {
                self.windows.focus(follow, pid: info.pid)
                Log.engine.info("window \(id) \(info.bundleID, privacy: .public): its desktop is shown (the owner just opened it)")
            }
        }
    }

    // MARK: - Helpers

    private var afterMouseUp: [() -> Void] = []
    private var mouseTimer: Timer?

    /// Nothing moves under a held mouse button (a tab being dragged out of a browser).
    private func whenMouseUp(_ action: @escaping () -> Void) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return action() }
        afterMouseUp.append(action)
        guard mouseTimer == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self.mouseTimer = nil
            let actions = self.afterMouseUp
            self.afterMouseUp.removeAll()
            actions.forEach { $0() }
        }
        RunLoop.main.add(timer, forMode: .common)
        mouseTimer = timer
    }

    /// A window's frame from the window list (AX coordinates), readable on any desktop.
    static func windowListFrame(_ id: UInt32) -> CGRect? {
        guard let entry = (CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]])?.first,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary else { return nil }
        return CGRect(dictionaryRepresentation: bounds)
    }

    /// When the owner's session at the console began (the record `who` reads), nil without one.
    private static func consoleLoginTime() -> Date? {
        func text<T>(_ field: inout T, _ size: Int32) -> String {
            withUnsafePointer(to: &field) { $0.withMemoryRebound(to: CChar.self, capacity: Int(size)) { String(cString: $0) } }
        }
        var latest: Date?
        setutxent()
        defer { endutxent() }
        while let entry = getutxent() {
            guard Int32(entry.pointee.ut_type) == USER_PROCESS,
                  text(&entry.pointee.ut_line, _UTX_LINESIZE) == "console",
                  text(&entry.pointee.ut_user, _UTX_USERSIZE) == NSUserName() else { continue }
            let at = Date(timeIntervalSince1970: TimeInterval(entry.pointee.ut_tv.tv_sec))
            if latest.map({ at > $0 }) ?? true { latest = at }
        }
        return latest
    }

    private static func systemBootTime() -> Date {
        var time = timeval()
        var size = MemoryLayout<timeval>.size
        var mib: [Int32] = [CTL_KERN, KERN_BOOTTIME]
        guard sysctl(&mib, 2, &time, &size, nil, 0) == 0 else { return .distantPast }
        return Date(timeIntervalSince1970: TimeInterval(time.tv_sec))
    }
}
