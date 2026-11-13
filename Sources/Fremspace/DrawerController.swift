import AppKit
import ApplicationServices
import FremspaceCore

/// Runs the drawers: which windows the owner sent where, opening (members at their drawer-slot
/// frames, above the main layout) and closing (members parked through a free side of the display,
/// spike `docs/spikes/2026-11-drawer-putaway.md`). Members are never placed or locked by the engine.
/// A drawer belongs to its display: its members follow the desktop the display shows.
final class DrawerController {
    /// Points of a parked window left visible: 1 is the least macOS accepts on a side (0 is pulled
    /// back to 40); through the bottom macOS keeps the title bar visible anyway.
    static let strip: CGFloat = 1
    /// Width asked for a window parked through the bottom (the app's minimum wins).
    static let tabWidth: CGFloat = 160

    /// The drawers of a display in the active configuration (at most one per edge); slot keys are
    /// `"<edge>.<slot id>"` (`drawerFrames([DrawerSpec], ...)`).
    var drawerSpecs: (DisplayIdentity) -> [DrawerSpec] = { _ in [] }
    /// Called when a window joins a drawer: the engine drops its placement and lock.
    var onJoin: (UInt32) -> Void = { _ in }
    /// Called when a window leaves a drawer: the engine may place it again.
    var onLeave: (UInt32) -> Void = { _ in }
    /// Whether the engine runs: commands and activations do nothing while paused or free.
    var isActive: () -> Bool = { false }
    /// Brings the front window of each main-layout slot that overlaps one of the given frames (the
    /// parked tabs) above them; stacked windows and other slots keep their order.
    /// The layout of a desktop, if it has one.
    var layoutOf: (SpaceKey) -> Layout? = { _ in nil }
    /// Covers the parked tabs (window id and frame) with the main layout.
    var raiseMainLayout: (SpaceKey, [(id: UInt32, frame: CGRect)]) -> Void = { _, _ in }
    /// Gives the keyboard to the main layout of a desktop (after closing its drawer by hotkey), or
    /// on a free desktop to the window in front.
    var focusMainLayout: (SpaceKey) -> Void = { _ in }

    private let windows: AXWindows
    private var state = DrawerState()
    private var members: [UInt32: (element: AXUIElement, pid: pid_t, bundleID: String)] = [:]
    var memberIDs: [UInt32] { Array(members.keys) }
    /// Each member's last open frame: restoring needs no configuration (it may be gone: free, error).
    private var openFrames: [UInt32: CGRect] = [:]
    private var mouseTimer: Timer?
    private var afterMouseUp: [() -> Void] = []
    private var draggedMembers: Set<UInt32> = []
    private var draggedOthers: Set<UInt32> = []
    /// Windows the owner took out of a drawer: their app's drawer slot does not take them back.
    private var takenOut: [UInt32: pid_t] = [:]

    /// Parked windows on disk (see `ParkedFile`), and those of a previous run not yet brought back.
    private let parkedURL: URL
    private var pendingRecovery: [ParkedWindow] = []

    init(windows: AXWindows, parkedURL: URL) {
        self.windows = windows
        self.parkedURL = parkedURL
    }

    // MARK: - Crash safety

    /// At launch: windows a previous run left parked (it crashed, or was killed) come back on screen.
    /// Those on a desktop not shown are retried on each desktop change (Accessibility lists the
    /// current desktop only).
    func recoverAfterCrash() {
        pendingRecovery = ParkedFile.load(parkedURL)
        if !pendingRecovery.isEmpty,
           !savedWindowsHold(savedAt: ParkedFile.savedAt(parkedURL), idsSince: DesktopRouter.windowIDsSince) {
            // Parked before this boot or login: those ids are other windows' now.
            Log.engine.notice("\(self.pendingRecovery.count) parked windows of an earlier session forgotten")
            pendingRecovery = []
        }
        if !pendingRecovery.isEmpty {
            Log.engine.notice("\(self.pendingRecovery.count) windows left parked by a previous run")
        }
        retryRecovery()
    }

    func retryRecovery() {
        guard !pendingRecovery.isEmpty else { return }
        var alive: [UInt32: Int32] = [:]
        for info in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            if let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32 {
                alive[id] = pid
            }
        }
        let plan = recoveryPlan(saved: pendingRecovery, alive: alive) { Self.bundleID(of: $0) }
        var restored: Set<UInt32> = []
        for parked in plan.restore {
            guard let element = windows.windowElements(pid: parked.pid).first(where: { AXWindows.windowID($0) == parked.id })
            else { continue }
            // An app too busy to move its window (at login) keeps its entry: it is tried again.
            guard windows.setFrame(element, parked.frame) == .success else { continue }
            restored.insert(parked.id)
            Log.engine.notice("window \(parked.id) \(parked.bundleID, privacy: .public) brought back from a previous run's drawer")
        }
        let done = restored.union(plan.drop)
        pendingRecovery.removeAll { done.contains($0.id) }
        saveParked()
    }

    /// Writes every member parked now (its drawer closed, or its window could not be moved back),
    /// plus what is still to recover.
    private func saveParked() {
        var parked = pendingRecovery
        for id in parkedMembers(state, notBroughtBack: notBroughtBack) {
            guard let member = members[id], let frame = openFrames[id] else { continue }
            parked.append(ParkedWindow(id: id, pid: member.pid, bundleID: member.bundleID, frame: frame))
        }
        do {
            try ParkedFile.save(parked.sorted { $0.id < $1.id }, to: parkedURL)
        } catch {
            Log.engine.error("cannot write the parked windows file: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The element of a drawer member, wherever it is parked.
    func member(_ id: UInt32) -> (element: AXUIElement, pid: pid_t)? {
        members[id].map { ($0.element, $0.pid) }
    }

    func isMember(_ id: UInt32) -> Bool {
        members[id] != nil
    }

    // MARK: - Across a restart

    /// Who is in which drawer and which windows were taken out, to keep across a restart.
    var membership: (members: [SavedDrawerMember], takenOut: [SavedWindow]) {
        var saved = members.compactMap { id, member -> SavedDrawerMember? in
            guard let display = state.display(of: id), let slot = state.slot(of: id) else { return nil }
            return SavedDrawerMember(window: SavedWindow(id: id, pid: member.pid), bundleID: member.bundleID,
                                     display: display, slot: slot)
        }
        // Those still waiting to be read are members too: saving now must not forget them.
        saved += waiting.filter { members[$0.window.id] == nil }
        return (saved.sorted { $0.window.id < $1.window.id },
                takenOut.map { SavedWindow(id: $0.key, pid: $0.value) }.sorted { $0.id < $1.id })
    }

    /// At start: the windows that were in a drawer when Fremspace stopped are in it again, parked,
    /// when the window, its display's drawer and its slot still exist. Windows taken out stay out.
    func rejoin(_ saved: [SavedDrawerMember], takenOut savedOut: [SavedWindow]) {
        waiting.removeAll()
        var alive: [UInt32: Int32] = [:]
        for info in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            if let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32 {
                alive[id] = pid
            }
        }
        for window in savedOut where window.isAlive(alive) { takenOut[window.id] = window.pid }
        var edges: [DisplayIdentity: Set<String>] = [:]
        for entry in saved where entry.isAlive(alive, app: Self.bundleID(of:)) && members[entry.window.id] == nil {
            let id = entry.window.id, edge = drawerEdge(ofSlotKey: entry.slot)
            guard let spec = drawerSpecs(entry.display).first(where: { $0.edge.rawValue == edge }),
                  spec.layout.slots.contains(where: { "\(edge).\($0.id)" == entry.slot }) else { continue }
            guard let element = windows.allWindows(pid: entry.window.pid).first(where: { AXWindows.windowID($0) == id }) else {
                // The window lives but cannot be read now (the session is locked, its app is busy):
                // it stays a member, and is read again later (`retryRejoin`). Until then it sits
                // where the last quit put it back: in sight on its desktop, following nothing.
                Log.engine.notice("drawer member \(id) \(entry.bundleID, privacy: .public) cannot be read yet: it joins its drawer when it can")
                waiting.append(entry)
                continue
            }
            join(id, element: element, pid: entry.window.pid, bundleID: entry.bundleID, display: entry.display, slot: entry.slot)
            edges[entry.display, default: []].insert(edge)
        }
        for (display, edges) in edges {
            whenMouseUp { [weak self] in self?.close(display, edges: edges) }
        }
    }

    private static func bundleID(of pid: Int32) -> String? {
        NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
    }

    /// Saved members whose window could not be read at start.
    private var waiting: [SavedDrawerMember] = []
    var hasWaitingMembers: Bool { !waiting.isEmpty }
    var waitingCount: Int { waiting.count }

    /// Reads the members that could not be read at start again: the session was unlocked, a moment
    /// passed, or a display changed desktop (a window of the desktop shown is always readable).
    func retryRejoin() {
        guard !waiting.isEmpty else { return }
        let pending = waiting
        rejoin(pending, takenOut: [])
        Log.engine.notice("\(pending.count - self.waiting.count) of \(pending.count) drawer members read again")
    }

    // MARK: - Commands

    /// Opens or closes the drawer of `edge` on the display under the mouse pointer.
    func toggleOnDisplayUnderMouse(_ edge: DrawerEdge) {
        guard isActive(), let display = displayUnderMouse(),
              drawerSpecs(display).contains(where: { $0.edge == edge }) else {
            NSSound.beep()
            return
        }
        // Windows of this drawer's apps left on another desktop (a closed drawer does not follow, and
        // after a restart only the windows of the desktop shown were seen) join it again.
        adoptStrays(display, edge: edge)
        // Members of this drawer still on another desktop of the display come to the one shown first.
        bring(display, edges: [edge.rawValue]) { [weak self] _ in
            guard let self else { return }
            self.prune(display)
            guard !self.state.stacks(display, edge: edge.rawValue).isEmpty else { return NSSound.beep() }
            if self.state.isOpen(display, edge: edge.rawValue) {
                self.close(display, edges: [edge.rawValue])
                // The other drawer, still open, keeps the keyboard; else it goes back to the layout.
                if !self.state.isOpen(display), let space = self.shown(display) { self.focusMainLayout(space) }
            } else {
                self.open(display, edges: [edge.rawValue], keyboardTo: nil)
            }
        }
    }

    /// Whether the drawer of `edge` on `display` is open.
    func isOpen(_ edge: DrawerEdge, on display: DisplayIdentity) -> Bool {
        state.isOpen(display, edge: edge.rawValue)
    }

    /// Until when the drawers of a display stay open whatever window of its layout is activated.
    private var heldOpen: [DisplayIdentity: Date] = [:]
    /// Until when a window that becomes active was picked by macOS, not by the owner: a display
    /// that arrives on a desktop gives the keyboard to a window of it, and the parked members of a
    /// closed drawer live on one. Taken for the owner's choice, that opened the drawer by itself
    /// (owner, 2026-11-12: the left drawer unfolded on the free desktop).
    private var systemPicksUntil = Date.distantPast
    private static let systemPickTime: TimeInterval = 1.5

    /// A display changed desktop.
    func desktopChanged() {
        systemPicksUntil = Date().addingTimeInterval(Self.systemPickTime)
    }

    /// For a moment, a window of the layout of `display` coming forward does not close its
    /// drawers: a scene brings one forward (to show a desktop, to give Focus) and wants the
    /// drawer open over it.
    func holdOpen(_ display: DisplayIdentity, for seconds: TimeInterval) {
        heldOpen[display] = max(heldOpen[display] ?? .distantPast, Date().addingTimeInterval(seconds))
    }

    /// Opens or closes the drawer of `edge` on `display`, for a scene. Nothing when the drawer
    /// holds no window, or is closed already; one that is open already comes in front again (the
    /// scene may just have put a slot in Focus over it).
    func set(_ edge: DrawerEdge, on display: DisplayIdentity, open wanted: Bool) {
        guard isActive(), drawerSpecs(display).contains(where: { $0.edge == edge }) else { return }
        guard wanted else {
            guard state.isOpen(display, edge: edge.rawValue) else { return }
            close(display, edges: [edge.rawValue])
            if !state.isOpen(display), let space = shown(display) { focusMainLayout(space) }
            return
        }
        adoptStrays(display, edge: edge)
        bring(display, edges: [edge.rawValue]) { [weak self] _ in
            guard let self else { return }
            self.prune(display)
            guard !self.state.stacks(display, edge: edge.rawValue).isEmpty else { return }
            self.open(display, edges: [edge.rawValue], keyboardTo: nil)
        }
    }

    /// Sends the active window to the drawer of `edge` on its display; a member of that drawer is
    /// taken out instead, and a member of the other drawer changes drawer.
    func sendOrTakeOutActiveWindow(_ edge: DrawerEdge) {
        guard isActive(), let element = windows.focusedWindow(), let id = AXWindows.windowID(element) else {
            NSSound.beep()
            return
        }
        guard let member = members[id] else { return send(element, edge: edge) }
        guard let display = state.display(of: id), let slot = state.slot(of: id) else { return }
        if drawerEdge(ofSlotKey: slot) == edge.rawValue { return takeOut(id) }
        guard let target = drawerSpecs(display).first(where: { $0.edge == edge })?.layout.slots.first else { return NSSound.beep() }
        state.send(id, to: display, slot: "\(edge.rawValue).\(target.id)")
        Log.engine.info("window \(id) \(member.bundleID, privacy: .public) moved to the \(edge.rawValue, privacy: .public) drawer")
        open(display, edges: [edge.rawValue], keyboardTo: id)
    }

    /// A window of an app that has a drawer slot (`slot`, a slot key of `display`) joins it by itself:
    /// shown at once when the owner is on it, parked otherwise. Not one the owner took out.
    func adopt(_ element: AXUIElement, _ info: WindowInfo, display: DisplayIdentity, slot: String) {
        guard isActive(), members[info.id] == nil, takenOut[info.id] == nil, !draggedOthers.contains(info.id) else { return }
        let edge = drawerEdge(ofSlotKey: slot)
        join(info.id, element: element, pid: info.pid, bundleID: info.bundleID, display: display, slot: slot)
        let inFront = windows.focusedWindow().flatMap(AXWindows.windowID) == info.id
        whenMouseUp { [weak self] in
            guard let self, self.members[info.id] != nil else { return }
            if inFront || self.state.isOpen(display, edge: edge) {
                self.open(display, edges: [edge], keyboardTo: inFront ? info.id : nil)
            } else {
                self.close(display, edges: [edge])
            }
        }
    }

    /// The windows of the apps of the drawer of `edge` that are on another desktop of `display` become
    /// members where they are; `bring` then fetches them.
    private func adoptStrays(_ display: DisplayIdentity, edge: DrawerEdge) {
        let specs = drawerSpecs(display).filter { $0.edge == edge }
        let apps = Set(specs.flatMap { $0.layout.slots.flatMap { $0.rules.map(\.bundleID) } })
        guard !apps.isEmpty else { return }
        let managed = Spaces.managed()
        let displays = Displays.connected()
        for app in NSWorkspace.shared.runningApplications {
            guard let bundleID = app.bundleIdentifier, apps.contains(bundleID) else { continue }
            for element in windows.allWindows(pid: app.processIdentifier) {
                guard let info = windows.info(for: element, pid: app.processIdentifier, bundleID: bundleID),
                      members[info.id] == nil, takenOut[info.id] == nil,
                      let place = Spaces.spaceIndex(ofWindow: info.id, managed: managed, displays: displays),
                      place.display == display,
                      let slot = drawerSlotKey(for: info, in: specs, layout: layoutOf(place)) else { continue }
                join(info.id, element: element, pid: info.pid, bundleID: info.bundleID, display: display, slot: slot)
            }
        }
    }

    /// Whether the owner took this window out of a drawer.
    func wasTakenOut(_ id: UInt32) -> Bool { takenOut[id] != nil }

    /// The drawer edges of the display a window is on ("Add to left / right drawer").
    func edges(forWindow id: UInt32) -> [DrawerEdge] {
        guard isActive(), members[id] == nil, let space = Spaces.spaceIndex(ofWindow: id) else { return [] }
        return drawerSpecs(space.display).map(\.edge)
    }

    /// Parks a window in a drawer of its display and opens it: the drawer of `edge` (its first slot),
    /// or with no edge the drawer slot under the mouse, else the first one.
    func send(_ element: AXUIElement, edge: DrawerEdge?) {
        guard isActive(), let id = AXWindows.windowID(element), members[id] == nil,
              let space = Spaces.spaceIndex(ofWindow: id), case let specs = drawerSpecs(space.display), !specs.isEmpty,
              let display = Displays.connected().first(where: { $0.identity == space.display }) else {
            NSSound.beep()
            return
        }
        takenOut[id] = nil
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
        // A dialog, sheet, panel or browser popup has the keyboard: it is not a window to park.
        guard windows.info(for: element, pid: pid, bundleID: bundleID)?.isManageable == true else {
            Log.engine.info("window \(id) \(bundleID, privacy: .public) is not a standard window; not sent to the drawer")
            return NSSound.beep()
        }
        let target: String?
        if let edge {
            target = specs.first { $0.edge == edge }.flatMap { spec in spec.layout.slots.first.map { "\(spec.edge.rawValue).\($0.id)" } }
        } else {
            let frames = drawerFrames(specs, visible: display.visibleAX, gap: Engine.gap)
            let first = specs.first.flatMap { spec in spec.layout.slots.first.map { "\(spec.edge.rawValue).\($0.id)" } }
            target = mouseAX().flatMap { slot(at: $0, in: frames) } ?? first
        }
        guard let target else { return NSSound.beep() }
        join(id, element: element, pid: pid, bundleID: bundleID, display: space.display, slot: target)
        open(space.display, edges: [drawerEdge(ofSlotKey: target)], keyboardTo: id)
    }

    /// A window became the active one: a parked member opens its drawer, the main layout closes it.
    func handleActivated(_ id: UInt32, isMainLayoutWindow: Bool) {
        guard isActive() else { return }
        let display = state.display(of: id) ?? Spaces.spaceIndex(ofWindow: id)?.display
        // An activated member also becomes the front of its slot (⌘Tab shows the window picked).
        switch activate(id, on: display, state: &state, isMainLayoutWindow: isMainLayoutWindow) {
        case .open(let display, let edge):
            if Date() < systemPicksUntil {
                // Not the owner's choice: the drawer stays closed and the keyboard goes to a window
                // that can be seen, not to one parked off screen.
                Log.engine.notice("window \(id) of the \(edge, privacy: .public) drawer of \(display.name, privacy: .public) became active as the display changed desktop: the drawer stays closed")
                if let space = shown(display) { focusMainLayout(space) }
                break
            }
            Log.engine.notice("the \(edge, privacy: .public) drawer of \(display.name, privacy: .public) opens: its window \(id) became the active one")
            whenMouseUp { [weak self] in self?.open(display, edges: [edge], keyboardTo: id) }
        case .close(let display):
            // A scene just brought this layout window forward itself: not the owner going back to
            // the layout.
            if let until = heldOpen[display], Date() < until { break }
            // The display just changed desktop: macOS gives the keyboard to a window of the desktop
            // that arrives. Not the owner going back to the layout: the open drawer follows and
            // stays open (owner, 2026-11-13: closed here, it flashed on each desktop and was gone).
            if Date() < systemPicksUntil {
                Log.engine.notice("window \(id) of the layout became active as \(display.name, privacy: .public) changed desktop: its open drawers stay open")
                break
            }
            // A mouse-down on a layout window may be the start of a drag into the open drawer: decide
            // on release, and keep the drawer open if the window lands in it.
            whenMouseUp { [weak self] in
                guard let self, self.dropTarget(for: id) == nil else { return }
                self.close(display)
            }
        case .none:
            break
        }
    }

    /// A member moved or resized. Only the user's own drags count (the button is down while the event
    /// arrives; moves by apps or by Fremspace are ignored, so nothing loops): on release, a member
    /// dropped in another drawer slot moves there, otherwise it goes back to its slot (owner,
    /// 2026-11-09: a drawer window stays in the drawer; the send hotkey takes it out).
    func handleFrameChanged(_ id: UInt32) {
        guard isActive(), members[id] != nil, state.isShown(id),
              NSEvent.pressedMouseButtons & 1 != 0, !draggedMembers.contains(id) else { return }
        draggedMembers.insert(id)
        whenMouseUp { [weak self] in
            guard let self else { return }
            self.draggedMembers.remove(id)
            self.settle(id, droppedAt: self.mouseAX())
        }
    }

    /// Another window is being dragged: if it is released inside the open drawer of its display, it
    /// joins the drawer slot under the pointer.
    func watchDrop(_ id: UInt32) {
        guard isActive(), members[id] == nil, NSEvent.pressedMouseButtons & 1 != 0,
              !draggedOthers.contains(id) else { return }
        draggedOthers.insert(id)
        whenMouseUp { [weak self] in
            guard let self else { return }
            self.draggedOthers.remove(id)
            guard let (display, slotID) = self.dropTarget(for: id),
                  let element = self.windows.focusedWindow(), AXWindows.windowID(element) == id else { return }
            var pid: pid_t = 0
            AXUIElementGetPid(element, &pid)
            let bundleID = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier ?? "?"
            self.join(id, element: element, pid: pid, bundleID: bundleID, display: display, slot: slotID)
            self.open(display, edges: [drawerEdge(ofSlotKey: slotID)], keyboardTo: id)
        }
    }

    /// The open drawer slot under the pointer, on the display of window `id`, if any. The engine asks
    /// before snapping a locked window back, so a window dropped into the drawer is not fought.
    func dropTarget(for id: UInt32) -> (DisplayIdentity, String)? {
        guard isActive(), members[id] == nil, let pointer = mouseAX(),
              let identity = Spaces.spaceIndex(ofWindow: id)?.display, state.isOpen(identity),
              let display = Displays.connected().first(where: { $0.identity == identity }),
              let slotID = slot(at: pointer, in: openFrames(identity, display)) else {
            return nil
        }
        return (identity, slotID)
    }

    private func settle(_ id: UInt32, droppedAt pointer: CGPoint?) {
        guard let member = members[id], let identity = state.display(of: id), state.isShown(id),
              let display = Displays.connected().first(where: { $0.identity == identity }) else { return }
        // Only a slot of an open drawer is a target: the closed one shows nothing to drop on.
        let frames = openFrames(identity, display)
        if let pointer, let target = slot(at: pointer, in: frames), target != state.slot(of: id) {
            state.send(id, to: identity, slot: target)
            Log.engine.info("window \(id) \(member.bundleID, privacy: .public) moved to drawer slot \(target, privacy: .public)")
        }
        guard let slotID = state.slot(of: id), let frame = frames[slotID] else { return }
        openFrames[id] = frame
        windows.setFrame(member.element, frame)
    }

    /// The slot frames of the open drawers of a display.
    private func openFrames(_ identity: DisplayIdentity, _ display: Displays.Connected) -> [String: CGRect] {
        let open = state.openEdges(identity)
        return drawerFrames(drawerSpecs(identity).filter { open.contains($0.edge.rawValue) }, visible: display.visibleAX, gap: Engine.gap)
    }

    // MARK: - Slot navigation

    /// The region key (`"drawer:<slot key>"`) of a member and the desktop its display shows, for slot
    /// navigation.
    func region(of id: UInt32) -> (SpaceKey, String)? {
        guard members[id] != nil, let display = state.display(of: id), let space = shown(display),
              let slot = state.slot(of: id) else { return nil }
        return (space, "drawer:\(slot)")
    }

    /// The members sharing the drawer slot of member `id`, itself included.
    func stack(of id: UInt32) -> [UInt32: (AXUIElement, pid_t)]? {
        guard members[id] != nil, let display = state.display(of: id), let slot = state.slot(of: id) else { return nil }
        var stack: [UInt32: (AXUIElement, pid_t)] = [:]
        for other in state.stacks(display)[slot] ?? [] {
            if let member = members[other] { stack[other] = (member.element, member.pid) }
        }
        return stack
    }

    /// The open drawers of the display of `space`: their slots holding members (keyed
    /// `"drawer:<slot key>"`), the front member of each, and the drawer zones.
    func openRegions(_ space: SpaceKey) -> (frames: [String: CGRect], fronts: [String: (AXUIElement, pid_t)], zones: [CGRect]) {
        let open = state.openEdges(space.display)
        guard case let specs = drawerSpecs(space.display).filter({ open.contains($0.edge.rawValue) }), !specs.isEmpty,
              let display = Displays.connected().first(where: { $0.identity == space.display }) else { return ([:], [:], []) }
        let all = drawerFrames(specs, visible: display.visibleAX, gap: Engine.gap)
        var frames: [String: CGRect] = [:]
        var fronts: [String: (AXUIElement, pid_t)] = [:]
        for (slotID, stack) in state.stacks(space.display) {
            guard let frame = all[slotID], let front = stack.first, let member = members[front] else { continue }
            frames["drawer:\(slotID)"] = frame
            fronts["drawer:\(slotID)"] = (member.element, member.pid)
        }
        return (frames, fronts, specs.map { drawerZone($0, visible: display.visibleAX) })
    }

    /// A window was destroyed (or its app quit): it leaves its drawer.
    func forget(_ id: UInt32) {
        takenOut[id] = nil
        guard members.removeValue(forKey: id) != nil else { return }
        openFrames[id] = nil
        notBroughtBack.remove(id)
        state.remove(id)
        saveParked()
        Log.engine.info("drawer member \(id) gone")
    }

    func forgetApp(_ pid: pid_t) {
        for (id, member) in members where member.pid == pid { forget(id) }
    }

    /// Brings every member back on screen at its drawer-slot frame (quit, pause, free, display
    /// change), so no window stays parked. Members whose display is gone are let go: macOS already
    /// moved them to a remaining display.
    func restoreAll() {
        // Members of a display that is gone stay members: they are restored when it comes back.
        let plan = restorePlan(state, connected: Set(Displays.connected().map(\.identity)))
        let failed = plan.restore.filter { !bringBack($0) }
        // Once more at once: when Fremspace is quitting there is no later.
        let left = failed.filter { !bringBack($0) }
        for id in left {
            Log.engine.error("drawer member \(id) \(self.members[id]?.bundleID ?? "?", privacy: .public) could not be brought back on screen (its app does not answer): kept as parked, tried again")
        }
        for display in Set(plan.restore.compactMap { state.display(of: $0) }) { state.setOpen(display, true) }
        saveParked()
        bringBackRound += 1
        retryBringBack(after: [1, 3, 10, 30], round: bringBackRound)
    }

    /// The Dock or a menu bar took or gave room on a display: the open drawers are placed again in
    /// the room there is now. The closed ones stay parked.
    func visibleAreaChanged() {
        guard isActive() else { return }
        for display in Set(state.allMembers.compactMap { state.display(of: $0) }) where state.isOpen(display) {
            place(display)
        }
    }

    /// Members whose drawer is open (or was opened to bring everything back) and whose window
    /// could not be moved to its place: an app busy past the Accessibility timeout. They are still
    /// off screen, so the parked file keeps them (`parkedMembers`) and they are tried again.
    private var notBroughtBack: Set<UInt32> = []
    /// The latest `restoreAll`: only its retries go on.
    private var bringBackRound = 0

    /// Moves a member to its last open frame. False when the window is not there afterwards.
    private func bringBack(_ id: UInt32) -> Bool {
        guard let member = members[id], let frame = openFrames[id] else { return true }
        let result = windows.setFrame(member.element, frame)
        // A window that refuses the size (a fixed one) answers with an error and moves all the
        // same: where it is tells. An app that did not answer is not asked again.
        let moved = result == .success || (result != .cannotComplete
            && windows.frame(member.element).map { abs($0.minX - frame.minX) <= 1 && abs($0.minY - frame.minY) <= 1 } == true)
        if moved { notBroughtBack.remove(id) } else { notBroughtBack.insert(id) }
        return moved
    }

    private func retryBringBack(after delays: [TimeInterval], round: Int) {
        guard !notBroughtBack.isEmpty, let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, round == self.bringBackRound else { return }
            for id in self.notBroughtBack {
                // Its drawer was closed again meanwhile: parked is where it belongs now.
                guard self.members[id] != nil, self.state.isShown(id) else {
                    self.notBroughtBack.remove(id)
                    continue
                }
                if self.bringBack(id) { Log.engine.notice("drawer member \(id) brought back on screen at last") }
            }
            self.saveParked()
            self.retryBringBack(after: Array(delays.dropFirst()), round: round)
        }
    }

    // MARK: - Open, close

    // MARK: - Following the desktop shown

    /// The displays showed another desktop: the members of the open drawers come along. A closed
    /// drawer stays where it was closed and comes when it is opened (owner, 2026-11-10: parked
    /// windows moved at every swipe showed their title bars at the bottom of each desktop).
    func followShownDesktops() {
        guard isActive() else { return }
        for display in Set(state.allMembers.compactMap { state.display(of: $0) }) {
            let open = state.openEdges(display)
            guard !open.isEmpty else { continue }
            bring(display, edges: open) { [weak self] moved in
                guard let self, moved else { return }
                // Above the layout of the desktop that arrived, with the keyboard, as they were on
                // the desktop left: macOS has just put a window of this one in front.
                self.show(display, edges: self.state.openEdges(display), keyboardTo: nil)
                Log.engine.notice("the open drawers of \(display.name, privacy: .public) followed to the desktop shown")
            }
        }
    }

    /// Sends the members of the drawers of `edges` that are on another desktop of `display` to the
    /// one it shows, then calls `then` (with true when some had to move).
    private func bring(_ display: DisplayIdentity, edges: Set<String>, then: @escaping (Bool) -> Void) {
        let strays = membersToBring(state, shown: Spaces.current()) { Spaces.spaceIndex(ofWindow: $0) }
            .filter { stray in
                stray.to.display == display
                    && state.slot(of: stray.id).map { edges.contains(drawerEdge(ofSlotKey: $0)) } == true
            }
        guard let target = strays.first?.to else { return then(false) }
        guard SpaceMover.isPresent, let sid = Spaces.spaceID(display: display, real: target.spaceIndex) else {
            Log.engine.notice("drawer on \(display.name, privacy: .public): \(strays.count) windows are on another desktop and cannot be brought here")
            return then(false)
        }
        let started = Date()
        var waiting = strays.count
        for stray in strays {
            SpaceMover.send(stray.id, toSpace: sid, lookEvery: SpaceMover.eagerPollInterval) { [weak self] arrived in
                if !arrived {
                    Log.engine.error("drawer member \(stray.id) could not follow to desktop \(target.spaceIndex + 1) of \(display.name, privacy: .public)")
                }
                waiting -= 1
                guard waiting == 0, let self else { return }
                Log.engine.info("\(strays.count) drawer members followed to desktop \(target.spaceIndex + 1) of \(display.name, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                // The owner went on to another desktop meanwhile: once more, from where things are.
                if Spaces.current()[display] != target.spaceIndex {
                    self.bring(display, edges: edges, then: then)
                } else {
                    then(true)
                }
            }
        }
    }

    /// The desktop a display shows (none on a full-screen Space).
    private func shown(_ display: DisplayIdentity) -> SpaceKey? {
        Spaces.current()[display].map { SpaceKey(display: display, spaceIndex: $0) }
    }

    // MARK: - Open, close

    /// Members of `display` no longer on screen were closed: some apps (Finder) hide a closed window
    /// instead of destroying it, so no destroyed event comes.
    private func prune(_ display: DisplayIdentity) {
        // Behind the lock screen every app lists no window while its windows live on: nothing can
        // be told closed there (a link or a scene run by a script reaches this with the Mac locked).
        guard !Engine.sessionIsLocked else { return }
        let shown = shown(display)
        // Per app: its window ids, or nil when it did not answer (busy): its members are then kept,
        // a parked window is never let go on a missing answer.
        var listed: [pid_t: Set<UInt32>?] = [:]
        for id in state.stacks(display).values.flatMap({ $0 }) {
            guard let member = members[id] else { continue }
            if listed[member.pid] == nil {
                let running = NSRunningApplication(processIdentifier: member.pid) != nil
                var answer = windows.windowElementsIfAnswered(pid: member.pid).map { Set($0.compactMap(AXWindows.windowID)) }
                // The seconds after the unlock give the same empty lists as the lock screen: an app
                // that lists nothing while its members are still shown has not answered. (The
                // window list is read only for an empty answer.)
                if let ids = answer, ids.isEmpty {
                    let own = Set(members.filter { $0.value.pid == member.pid }.keys)
                    if !windowListAnswers(listed: ids, onScreen: AXWindows.onScreenWindowIDs().intersection(own)) {
                        Log.engine.notice("drawer: pid \(member.pid) lists no window while its members are on screen; they are kept")
                        answer = nil
                    }
                }
                listed.updateValue(answer ?? (running ? nil : []), forKey: member.pid)
            }
            guard let inList = listed[member.pid] ?? nil else { continue }
            let hidden = NSRunningApplication(processIdentifier: member.pid)?.isHidden ?? false
            // A member still on another desktop (it could not follow) is not listed either: only one
            // that is on the desktop shown, or on none any more, can be told closed.
            let place = Spaces.spaceIndex(ofWindow: id)
            let onShownDesktop = shown != nil && (place == nil || place == shown)
            if memberIsGone(spaceIsShown: onShownDesktop, appHidden: hidden, inAppWindowList: inList.contains(id)) {
                forget(id)
            }
        }
    }

    /// After a configuration reload: members whose drawer slot no longer exists come back on screen and
    /// leave the drawer (nothing stays parked in a drawer that is gone).
    func reconcile() {
        let stale = staleMembers(state) { [weak self] display in
            guard let self else { return [] }
            return Set(self.drawerSpecs(display).flatMap { spec in spec.layout.slots.map { "\(spec.edge.rawValue).\($0.id)" } })
        }
        for id in stale {
            if let member = members[id], let frame = openFrames[id] { windows.setFrame(member.element, frame) }
            forget(id)
        }
    }

    /// Opens the drawers of `edges` (a display's other drawer stays as it is). Their members left on
    /// another desktop of the display come first.
    private func open(_ identity: DisplayIdentity, edges: Set<String>, keyboardTo preferred: UInt32?) {
        bring(identity, edges: edges) { [weak self] _ in
            self?.openNow(identity, edges: edges, keyboardTo: preferred)
        }
    }

    private func openNow(_ identity: DisplayIdentity, edges: Set<String>, keyboardTo preferred: UInt32?) {
        prune(identity)
        let started = Date()
        for edge in edges { state.setOpen(identity, edge: edge, true) }
        show(identity, edges: edges, keyboardTo: preferred)
        saveParked()
        Log.engine.info("\(edges.sorted().joined(separator: " and "), privacy: .public) drawer opened on \(identity.name, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    /// Puts the members of the open drawers at their slots and brings those of `edges` above the
    /// main layout; `preferred`, else the first front member, gets the keyboard.
    private func show(_ identity: DisplayIdentity, edges: Set<String>, keyboardTo preferred: UInt32?) {
        guard !edges.isEmpty, let placed = place(identity) else { return }
        let fronts = placed.filter { id in state.slot(of: id).map { edges.contains(drawerEdge(ofSlotKey: $0)) } == true }
        // Each front member comes above the main layout; the preferred one gets the keyboard last.
        let keyboard = preferred.flatMap { id in fronts.contains(id) ? id : nil } ?? fronts.first
        for id in fronts where id != keyboard {
            if let member = members[id] { windows.focus(member.element, pid: member.pid) }
        }
        if let keyboard, let member = members[keyboard] { windows.focus(member.element, pid: member.pid) }
    }

    /// Puts the members of the open drawers at their slots, without touching the keyboard. Returns the
    /// front member of each slot, nil when the display has no drawer or is gone.
    @discardableResult
    private func place(_ identity: DisplayIdentity) -> [UInt32]? {
        guard case let specs = drawerSpecs(identity), !specs.isEmpty,
              let display = Displays.connected().first(where: { $0.identity == identity }) else { return nil }
        let frames = drawerFrames(specs, visible: display.visibleAX, gap: Engine.gap)
        let open = state.openEdges(identity)
        var fronts: [UInt32] = []
        for (slotID, stack) in state.stacks(identity) where open.contains(drawerEdge(ofSlotKey: slotID)) {
            guard let frame = frames[slotID] else { continue }
            // Back to front, so the front member ends on top of its stack.
            for id in stack.reversed() {
                guard members[id] != nil else { continue }
                openFrames[id] = frame
                // One whose app does not answer stays parked: the parked file keeps it.
                _ = bringBack(id)
            }
            if let front = stack.first { fronts.append(front) }
        }
        return fronts
    }

    /// Closes the drawers of `edges` (all of the display's with nil): their members are parked.
    private func close(_ identity: DisplayIdentity, edges: Set<String>? = nil) {
        guard case let all = drawerSpecs(identity), !all.isEmpty,
              let display = Displays.connected().first(where: { $0.identity == identity }) else { return }
        let specs = all.filter { edges?.contains($0.edge.rawValue) ?? true }
        let others = Displays.connected().filter { $0.identity != identity }.map(\.frameAX)
        let free = freeSides(of: display.frameAX, others: others)
        let frames = drawerFrames(specs, visible: display.visibleAX, gap: Engine.gap)
        /// Where a member of `spec` goes: out of sight through a side when one takes it, else
        /// through the bottom, where its title bar stays visible and it shrinks to a tab.
        func parkedFrame(_ frame: CGRect, _ spec: DrawerSpec) -> (frame: CGRect, isTab: Bool)? {
            if let hidden = hiddenParkedFrame(frame, display: display.frameAX, others: others, edge: spec.edge,
                                              strip: Self.strip) {
                return (hidden, false)
            }
            guard let side = parkSide(for: spec.edge, free: free, frame: frame, display: display.frameAX, others: others,
                                      strip: Self.strip) else { return nil }
            guard side == .bottom else {
                return (FremspaceCore.parkedFrame(frame, display: display.frameAX, side: side, strip: Self.strip), false)
            }
            return (compactParkedFrame(frame, display: display.frameAX, side: .bottom, strip: Self.strip, edge: spec.edge,
                                       width: Self.tabWidth, gap: Engine.gap), true)
        }
        let stacks = state.stacks(identity).compactMap { slotID, stack -> (frame: CGRect, spec: DrawerSpec, stack: [UInt32])? in
            guard let frame = frames[slotID], let spec = drawer(ofSlotKey: slotID, in: specs) else { return nil }
            return (frame, spec, stack)
        }
        guard stacks.allSatisfy({ parkedFrame($0.frame, $0.spec) != nil }) else {
            Log.engine.notice("drawer on \(identity.name, privacy: .public): no free side to park windows through")
            NSSound.beep()
            return
        }
        let started = Date()
        for spec in specs { state.setOpen(identity, edge: spec.edge.rawValue, false) }
        var tabs: [(id: UInt32, frame: CGRect)] = []
        for (frame, spec, stack) in stacks {
            guard let parked = parkedFrame(frame, spec) else { continue }
            for id in stack {
                guard let member = members[id] else { continue }
                // A member that never opened comes back to its drawer slot.
                if openFrames[id] == nil { openFrames[id] = frame }
                notBroughtBack.remove(id)
                windows.setFrame(member.element, parked.frame)
                if parked.isTab { tabs.append((id, parked.frame)) }
            }
        }
        // Through the bottom the title bar stays visible: the main layout goes over it, leaving at most
        // the bottom gap of a narrow tab.
        if !tabs.isEmpty, let space = shown(identity) { raiseMainLayout(space, tabs) }
        saveParked()
        Log.engine.info("\(specs.map(\.edge.rawValue).sorted().joined(separator: " and "), privacy: .public) drawer closed on \(identity.name, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    // MARK: - Membership

    /// The owner gave these apps a slot in a layout (saved): their windows that sit in a drawer
    /// leave it, for the layout to take them. Not from a drawer that names the app in one of its
    /// own slots: the configuration then says both, and the drawer had the window first.
    func release(apps: Set<String>) {
        guard !apps.isEmpty else { return }
        for (id, member) in Array(members) where apps.contains(member.bundleID) {
            guard let display = state.display(of: id) else { continue }
            let named = drawerSpecs(display).contains { spec in
                spec.layout.slots.contains { $0.rules.contains { $0.bundleID == member.bundleID } }
            }
            if !named { takeOut(id) }
        }
    }

    private func join(_ id: UInt32, element: AXUIElement, pid: pid_t, bundleID: String, display: DisplayIdentity, slot: String) {
        members[id] = (element, pid, bundleID)
        state.send(id, to: display, slot: slot)
        onJoin(id)
        Log.engine.info("window \(id) \(bundleID, privacy: .public) sent to drawer slot \(slot, privacy: .public)")
    }

    /// The member leaves its drawer and floats where it is; a parked one first comes back on screen.
    private func takeOut(_ id: UInt32) {
        guard let member = members[id], let identity = state.display(of: id) else { return }
        if !state.isShown(id), let slotID = state.slot(of: id),
           let display = Displays.connected().first(where: { $0.identity == identity }),
           let frame = drawerFrames(drawerSpecs(identity), visible: display.visibleAX, gap: Engine.gap)[slotID] {
            windows.setFrame(member.element, frame)
        }
        members[id] = nil
        openFrames[id] = nil
        notBroughtBack.remove(id)
        state.remove(id)
        takenOut[id] = member.pid
        saveParked()
        onLeave(id)
        Log.engine.info("window \(id) \(member.bundleID, privacy: .public) taken out of the drawer")
    }

    // MARK: - Helpers

    private func mouseAX() -> CGPoint? { Displays.mouseAX() }

    /// The display under the pointer, when it shows a desktop (not a full-screen Space).
    private func displayUnderMouse() -> DisplayIdentity? {
        guard let point = mouseAX(),
              let display = Displays.connected().first(where: { $0.frameAX.contains(point) }),
              Spaces.current()[display.identity] != nil else { return nil }
        return display.identity
    }

    /// Never move windows under a held mouse button (a click on a parked tab activates its window
    /// on mouse-down): run `action` once the button is up.
    private func whenMouseUp(_ action: @escaping () -> Void) {
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return action() }
        afterMouseUp.append(action)
        guard mouseTimer == nil else { return }
        mouseTimer = Timer(timeInterval: 0.05, repeats: true) { [weak self] timer in
            guard let self, NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self.mouseTimer = nil
            let actions = self.afterMouseUp
            self.afterMouseUp.removeAll()
            actions.forEach { $0() }
        }
        if let mouseTimer { RunLoop.main.add(mouseTimer, forMode: .common) }
    }
}
