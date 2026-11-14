import AppKit
import ApplicationServices
import FremspaceCore

enum EngineStatus: Equatable {
    case running(configuration: String)
    case free(reason: String)
    case paused
}

/// Places windows into the slots of the layout of the Space each display shows, keeps locked
/// windows in their slot, and toggles Focus. Never moves a window to another Space, never writes
/// the configuration file.
final class Engine {
    /// Space between windows, and between windows and the screen edges.
    static let gap: CGFloat = 8
    /// Frame changes this soon after our own `setFrame` on a window are ours, not the user's.
    static let fitCheckDelay: TimeInterval = 0.4
    static let fitRetries = 2
    static let ownMoveWindow: TimeInterval = 0.25

    /// Why nothing is applied when no configuration lists the connected displays.
    static let noConfigurationReason = "No configuration for these displays"

    var onStatusChange: ((EngineStatus) -> Void)?

    private(set) var status: EngineStatus = .free(reason: "Starting") {
        didSet {
            guard status != oldValue else { return }
            Log.engine.info("status \(String(describing: self.status), privacy: .public)")
            if case .running = oldValue, !isRunning {
                // Fremspace stops managing windows: no drawer member may stay parked.
                drawers.restoreAll()
            }
            onStatusChange?(status)
        }
    }

    var paused = false {
        didSet {
            guard paused != oldValue else { return }
            if paused {
                waitingForMouseUp.removeAll()
            } else {
                // Windows opened or moved during the pause are placed now, not at the next event.
                scheduleApply()
            }
            refreshStatus()
        }
    }

    private let store: ConfigStore
    private let stateStore: StateStore
    /// What Fremspace learned (desktop links), saved in `state.json` next to the configuration.
    private(set) var state: FremspaceState
    /// Configured ↔ real desktop positions of the active configuration.
    private var desktopMap = DesktopMap()
    /// Whether sending windows to another desktop works (a private SkyLight operation): not at
    /// all when it is missing on this macOS, which the Status page reads here too.
    private(set) var moverHealth = MoverHealth(present: SpaceMover.isPresent)

    /// Remembered placements waiting to be recorded (identities are read off the placement pass).
    private var pendingRecords: [UInt32: PendingRecord] = [:]
    private struct PendingRecord {
        var element: AXUIElement
        var info: WindowInfo
        var desktop: ConfiguredDesktop
        var slotID: String?
        var frame: CGRect
    }
    private var recordScheduled = false
    private var stateSaveScheduled = false
    /// The identity read for each live window, and the title it was read under.
    private var identities: [UInt32: (title: String, identity: WindowIdentity)] = [:]
    /// Windows not in a slot that moved: their remembered frame is updated once they settle.
    private var looseMoves: Set<UInt32> = []
    private var looseMovesScheduled = false
    static let recordDelay: TimeInterval = 1
    static let stateSaveDelay: TimeInterval = 2

    /// The private calls that this macOS no longer has (see `PrivateCalls`): what the status says
    /// when placing needs one, and what the Status page lists.
    var missingCalls: [PrivateCall] { PrivateCalls.missing }

    /// Fremspace can send windows to another desktop on this macOS.
    var canMoveBetweenDesktops: Bool { moverHealth.isAvailable }
    private let windows: AXWindows
    private let observer: WindowObserver

    private var config: Config?
    private var loadError: String?
    private var configuration: Configuration?
    /// A configured display that several connected displays claim to be (see `ambiguousDisplay`).
    private var ambiguous: DisplayIdentity?
    /// True while Fremspace drives Mission Control (adding desktops): nothing is placed or restored.
    private var suspended = false

    /// A window Fremspace put in a slot.
    private struct Placement {
        var element: AXUIElement
        var info: WindowInfo
        var space: SpaceKey
        var slotID: String
        var frame: CGRect
        var locked: Bool
    }

    private var placements: [UInt32: Placement] = [:]
    /// Windows that share their slot side by side (see `SplitSide`), and the process of each: the
    /// pairs are saved, so that a restart of Fremspace finds them again.
    private var splits: [UInt32: SplitSide] = [:]
    private var splitPids: [UInt32: Int32] = [:]
    /// A second window was asked of an app, to go beside `first`; `known` are the windows it had.
    private var pendingSplit: (pid: pid_t, first: UInt32, known: Set<UInt32>, asked: Date)?
    private var lockGuard = LockGuard()
    private var focus = FocusState()
    /// Desktops whose Focus changed while they were not shown: their next pass is forced.
    private var refocused: Set<SpaceKey> = []
    /// Where the user last put each window, when several slots match it, per desktop (a slot id
    /// is one of a desktop). Forgotten when the configuration is read again or the desktops
    /// change place: the keys are real positions, and it grew for as long as Fremspace ran.
    private var memory: [SpaceKey: [WindowKey: String]] = [:]
    /// Windows that fought the lock: left alone until they are destroyed.
    /// The slot the user dropped each live window into, by window id: survives title changes
    /// (browser tabs) and placement resets; dropped when the window goes or leaves its slot.
    private var chosenSlot: [UInt32: String] = [:]
    /// Windows whose app refuses their slot size (a minimum size larger than the slot): placed once
    /// as well as they fit, then left alone instead of fought.
    private var cannotFit: Set<UInt32> = []
    /// Minimum sizes learned from refused placements, for the editor's warnings.
    private(set) var minimumSizes = MinimumSizes()
    private var ownMoves: [UInt32: Date] = [:]
    /// The moves of each window into its slot that Accessibility refused in a row (see `moveRetry`).
    private var failedMoves: [UInt32: Int] = [:]
    /// Locked windows moved while the mouse button was down, re-checked on release.
    private var waitingForMouseUp: Set<UInt32> = []
    private var mouseTimer: Timer?
    private var applyScheduled = false
    /// A pass was due while the mouse button was down: it runs on release.
    private var applyAfterMouseUp = false
    private var unsupportedPolicyLogged: Set<String> = []
    private var trustTimer: Timer?
    private var screenToken: NSObjectProtocol?
    /// The displays Fremspace last acted on (see `displaysChange`).
    private var knownDisplays: [DisplayArea] = []
    /// macOS said the displays changed and they may still be changing (a Mac that wakes shows its
    /// own display, then the others): until they hold still nothing is placed, routed or taken for
    /// a move by hand, and no drawer moves (see `displaySettleDelay`).
    private var displaysSettling = false
    /// The latest notice of a change of displays: only its wait ends the settling.
    private var settleRound = 0
    /// The displays held still behind the lock screen, where no window can be read: what follows
    /// a change of displays runs at the unlock.
    private var displaysOwed = false
    /// The Mac or its displays went to sleep, and when they last woke.
    private var asleep = false
    private var lastWake = Date.distantPast
    private var sleepTokens: [NSObjectProtocol] = []
    /// For this long after a wake, a change of displays is taken for a step of the wake.
    private static let wakeTime: TimeInterval = 30

    private static func displayAreas() -> [DisplayArea] {
        Displays.connected().map { DisplayArea(identity: $0.identity, frame: $0.frameAX, visible: $0.visibleAX) }
    }

    let drawers: DrawerController
    /// Sends windows to the desktop they belong on.
    private(set) lazy var router = DesktopRouter(engine: self, windows: windows)

    /// Opens a file or a folder the owner asked for from Fremspace's own window or menu. The
    /// window that comes stays where it opens, whatever "no floating windows" says.
    func openForOwner(_ url: URL) {
        guard let app = NSWorkspace.shared.urlForApplication(toOpen: url).flatMap({ Bundle(url: $0)?.bundleIdentifier }) else {
            NSWorkspace.shared.open(url)
            return
        }
        router.expectWindow(of: app)
        bringHere(windowOf: app, showing: url) { NSWorkspace.shared.open(url) }
    }

    /// Shows files in the Finder for the owner, as `openForOwner` opens one.
    func revealForOwner(_ urls: [URL]) {
        router.expectWindow(of: Self.finder)
        guard let folder = urls.first?.deletingLastPathComponent() else { return }
        bringHere(windowOf: Self.finder, showing: folder) { NSWorkspace.shared.activateFileViewerSelecting(urls) }
    }

    private static let finder = "com.apple.finder"

    /// The app may already show `url` in a window on a desktop that is not shown: asked to open
    /// it, macOS takes the owner to that desktop instead of opening a window where they are
    /// (owner, 2026-11-13: the Layouts folder, still open on the free desktop from the time
    /// before). Such a window is first brought to the desktop its display shows; then `then`.
    private func bringHere(windowOf bundleID: String, showing url: URL, then: @escaping () -> Void) {
        guard SpaceMover.isPresent, AXIsProcessTrusted(), !Self.sessionIsLocked else { return then() }
        let shown = Spaces.current()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            for element in windows.allWindows(pid: app.processIdentifier) {
                // A window in a slot or in a drawer is where the layout wants it.
                guard let id = AXWindows.windowID(element), placements[id] == nil, !drawers.isMember(id),
                      let place = Spaces.spaceIndex(ofWindow: id), let here = shown[place.display], here != place.spaceIndex,
                      windowShows(url, document: windows.document(of: element), title: windows.title(of: element),
                                  byTitle: bundleID == Self.finder),
                      let space = Spaces.spaceID(display: place.display, real: here) else { continue }
                router.keepHere(id)
                Log.engine.info("window \(id) \(bundleID, privacy: .public) already shows what was asked for, on another desktop: brought to the one shown")
                SpaceMover.send(id, toSpace: space, lookEvery: SpaceMover.eagerPollInterval) { _ in then() }
                return
            }
        }
        then()
    }
    /// Commands on the active window (quick resize, send, lock).
    private(set) lazy var commands = WindowCommands(engine: self, windows: windows)
    /// Call windows that go to full screen when the call starts.
    private(set) lazy var calls: CallWatcher = {
        let calls = CallWatcher(windows: windows)
        calls.wants = { [weak self] bundleID in
            guard let self, self.isRunning, let config = self.config else { return false }
            return wantsFullScreenCalls(bundleID: bundleID, in: config)
        }
        return calls
    }()
    /// Restore at login and "Restore everything now".
    private(set) lazy var loginRestorer = LoginRestorer(engine: self, windows: windows)

    init(store: ConfigStore, windows: AXWindows, observer: WindowObserver) {
        self.store = store
        stateStore = StateStore(url: store.url.deletingLastPathComponent().appendingPathComponent("state.json"))
        let savedAt = stateStore.savedAt
        let saved = stateStore.load()
        // Written before this boot or login: the window ids in it are other windows' now, and the
        // apps opened at login get much the same ids and process numbers each time.
        if savedWindowsHold(savedAt: savedAt, idsSince: DesktopRouter.windowIDsSince) {
            state = saved
        } else {
            state = saved.withoutSavedWindows()
            Log.engine.notice("state.json is from an earlier session: its drawer members and side-by-side pairs are forgotten")
        }
        self.windows = windows
        self.observer = observer
        drawers = DrawerController(windows: windows,
                                   parkedURL: store.url.deletingLastPathComponent().appendingPathComponent("parked.json"))
        drawers.drawerSpecs = { [weak self] display in
            // Of the display, whichever desktop it shows (a free one too); none on an ignored display.
            guard let self, self.isRunning, let configuration = self.activeConfiguration else { return [] }
            return displaySpec(for: display, in: configuration)?.drawers ?? []
        }
        drawers.onJoin = { [weak self] id in
            // A drawer member is no longer the layout's: no placement, no lock.
            guard let self else { return }
            self.lockGuard.forget(id: id)
            self.placements[id] = nil
            self.cannotFit.remove(id)
            self.waitingForMouseUp.remove(id)
            self.rememberDrawers()
        }
        drawers.onLeave = { [weak self] _ in
            self?.rememberDrawers()
            self?.scheduleApply()
        }
        drawers.focusMainLayout = { [weak self] space in self?.focusMainLayout(space) }
        drawers.isActive = { [weak self] in
            guard let self else { return false }
            return self.isRunning && !self.displaysSettling
        }
        drawers.layoutOf = { [weak self] space in self?.spaceSpec(space)?.layout }
        drawers.raiseMainLayout = { [weak self] space, tabs in
            guard let self else { return }
            // Only the front window of each slot over a tab: raising a whole stack would reshuffle it
            // (owner saw the Brave stack change on every close).
            var fronts: [String: (placement: Placement, depth: Int)] = [:]
            var depth: [UInt32: Int] = [:]
            for (index, id) in AXWindows.onScreenWindowOrder().enumerated() {
                depth[id] = index
                guard let placement = self.placements[id], placement.space == space,
                      fronts[placement.slotID] == nil else { continue }
                fronts[placement.slotID] = (placement, index)
            }
            // With a slot in Focus, only its window: it covers the display, the tabs with it, and
            // a window of another slot raised over a tab came in front of it (owner, 2026-11-13:
            // at every start Brave, beside the right drawer's tab, covered the window in Focus).
            let focused = self.focus.slot(space)
            // Only a window that a tab is above: one already over its tabs is not touched (raising
            // the window the owner types in at every start took the keyboard out of its field).
            for (slotID, front) in fronts where (focused == nil || slotID == focused) && tabs.contains(where: { tab in
                tab.frame.intersects(front.placement.frame) && (depth[tab.id] ?? Int.max) < front.depth
            }) {
                self.windows.raise(front.placement.element)
            }
        }
    }

    /// The configured desktop for a Space in the active configuration.
    private func spaceSpec(_ space: SpaceKey) -> SpaceSpec? {
        guard isRunning else { return nil }
        return configuredSpec(space)
    }

    /// The configured desktop a real desktop is (through the desktop links), if any.
    private func configuredSpec(_ space: SpaceKey) -> SpaceSpec? {
        guard let configuration, let display = displaySpec(for: space.display, in: configuration),
              let index = desktopMap.configured(space.display, real: space.spaceIndex),
              index < display.spaces.count else { return nil }
        return display.spaces[index]
    }

    // MARK: - For the palette

    /// The element of a window Fremspace placed or parked, on whatever desktop it is now.
    func knownElement(_ id: UInt32) -> (element: AXUIElement, pid: pid_t)? {
        if let placement = placements[id] { return (placement.element, placement.info.pid) }
        return drawers.member(id)
    }

    /// The last title Fremspace read for a window (windows of other desktops cannot be asked).
    func knownTitle(_ id: UInt32) -> String? {
        identities[id]?.title ?? router.lastTitle(id)
    }

    /// The label and layout of a real desktop in the active configuration.
    func desktopSpec(_ space: SpaceKey) -> SpaceSpec? { spaceSpec(space) }

    /// The slot enlarged with the Focus hotkey on a desktop, if any.
    func focusedSlot(_ space: SpaceKey) -> String? { focus.slot(space) }

    /// The window to picture in each slot of a desktop, shown or not. The palette reads the
    /// windows of every desktop for its map; the editor asks it through here.
    var slotWindows: (ConfiguredDesktop) -> [String: UInt32] = { _ in [:] }
    /// The app's updater, when this build has one.
    let updates = Updates()

    /// The scenes of the active configuration.
    var scenes: [CoreScene] { isRunning ? configuration?.scenes ?? [] : [] }

    /// The scene in effect, and what it changed beyond the desktops. Kept in memory only: after a
    /// restart no scene is in effect, and what the last one changed stays as it is.
    private var sceneInEffect: (scene: CoreScene, changes: SceneChanges)?
    var sceneInEffectID: UUID? { sceneInEffect?.scene.id }

    /// The slot in Focus on a configured desktop, if any.
    func focusedSlot(on desktop: ConfiguredDesktop) -> String? {
        realSpace(desktop).flatMap { focus.slot($0) }
    }

    /// What a scene does beyond the desktops, once the displays show them: its Focus and its
    /// drawers. What it changed is kept, for `leaveScene`, with the displays it switched.
    func enter(_ scene: CoreScene, switches: [SceneChanges.Switch] = []) {
        guard isRunning, !paused, let configuration else { return }
        let focusSteps = sceneFocusSteps(scene, in: configuration, available: availableDesktops) { self.focusedSlot(on: $0) }
        let drawerSteps = sceneDrawerSteps(scene, in: configuration) { self.drawers.isOpen($1, on: $0) }
        // Giving Focus brings a window of the layout forward, which closes the drawers of its
        // display as if the owner had gone back to the layout: not those the scene wants open.
        keepDrawersOpen(of: scene, for: 1.5)
        setFocus(focusSteps.map { FocusSetting(desktop: $0.desktop, slotID: $0.slotID) })
        for drawer in drawerSteps where !drawer.open { drawers.set(drawer.edge, on: drawer.display, open: false) }
        // Every drawer the scene wants open, also one that is open already: it comes in front of
        // the slot just put in Focus.
        for drawer in scene.drawers where drawer.open && sceneHasDrawer(drawer, in: configuration) {
            drawers.set(drawer.edge, on: drawer.display, open: true)
        }
        let changes = SceneChanges(focus: focusSteps, drawers: drawerSteps, switches: switches)
        if let before = sceneInEffect, before.scene.id == scene.id {
            sceneInEffect = (scene, before.changes.merging(changes))
        } else {
            sceneInEffect = (scene, changes)
        }
        Log.engine.notice("scene \(scene.name, privacy: .public) in effect: \(focusSteps.count) Focus given, \(drawerSteps.count) drawers moved")
    }

    /// A display shows another desktop: a drawer the scene in effect opened there closes instead
    /// of following (see `sceneDrawersLeftBehind`). Asking for the scene again opens it again.
    private func closeSceneDrawersLeftBehind() {
        guard var inEffect = sceneInEffect else { return }
        var shown: Set<ConfiguredDesktop> = []
        for (display, real) in Spaces.current() {
            if let desktop = configuredDesktop(SpaceKey(display: display, spaceIndex: real)) { shown.insert(desktop) }
        }
        let left = sceneDrawersLeftBehind(inEffect.changes, desktops: inEffect.scene.desktops, shown: shown)
        guard !left.isEmpty else { return }
        for drawer in left { drawers.set(drawer.edge, on: drawer.display, open: false) }
        inEffect.changes.drawers.removeAll { left.contains($0) }
        sceneInEffect = inEffect
        Log.engine.notice("scene \(inEffect.scene.name, privacy: .public): \(left.count) drawers it opened closed, their display shows another desktop")
    }

    /// The drawers a scene wants open stay open for a moment whatever window of the layout comes
    /// forward: showing its desktops and giving its Focus both bring one forward.
    func keepDrawersOpen(of scene: CoreScene, for seconds: TimeInterval) {
        for drawer in scene.drawers where drawer.open { drawers.holdOpen(drawer.display, for: seconds) }
    }

    /// Leaves the scene in effect: the Focus it gave and the drawers it moved go back to what they
    /// were, unless the owner changed them since. Returns what the scene changed: the caller
    /// shows again the desktops its displays came from (see `sceneReturn`).
    @discardableResult
    func leaveScene() -> SceneChanges {
        guard let scene = sceneInEffect else { return SceneChanges() }
        sceneInEffect = nil
        let undo = sceneUndo(scene.changes, focused: { self.focusedSlot(on: $0) }, isOpen: { self.drawers.isOpen($1, on: $0) })
        setFocus(undo.focus)
        for drawer in undo.drawers { drawers.set(drawer.edge, on: drawer.display, open: drawer.open) }
        Log.engine.notice("scene left: \(undo.focus.count) Focus given back, \(undo.drawers.count) drawers put back")
        return scene.changes
    }

    /// Opens the apps of a scene that are not running, behind what is in front: their windows go
    /// to their slots as they appear.
    func openApps(of scene: CoreScene) {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for bundleID in sceneAppsToOpen(scene, running: running) {
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                Log.engine.error("scene \(scene.name, privacy: .public): \(bundleID, privacy: .public) is not installed")
                continue
            }
            let options = NSWorkspace.OpenConfiguration()
            options.activates = false
            NSWorkspace.shared.openApplication(at: url, configuration: options) { _, error in
                if let error {
                    Log.engine.error("scene: opening \(bundleID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
                }
            }
            Log.engine.info("scene \(scene.name, privacy: .public): opened \(bundleID, privacy: .public)")
        }
    }

    /// Gives Focus to a slot of each of these desktops, or takes it off (nil). On a desktop that
    /// is shown the windows move at once and the slot in Focus comes in front with the keyboard.
    private func setFocus(_ settings: [FocusSetting]) {
        guard !settings.isEmpty else { return }
        var changed: [(space: SpaceKey, slotID: String?)] = []
        for setting in settings {
            guard let space = realSpace(setting.desktop) else { continue }
            focus.set(space, slot: setting.slotID)
            changed.append((space, setting.slotID))
        }
        rememberFocus()
        let current = Spaces.current()
        for (space, slotID) in changed {
            guard current[space.display] == space.spaceIndex else {
                Log.engine.notice("focus \(slotID ?? "off", privacy: .public) set on a desktop that is not shown: its windows move when it is")
                refocused.insert(space)
                continue
            }
            apply(force: true, only: space)
            guard let slotID else { continue }
            // Of a stack, the window that was in front stays the one in front.
            let inSlot = placements.filter { $0.value.space == space && $0.value.slotID == slotID }
            guard let id = AXWindows.onScreenWindowOrder().first(where: { inSlot[$0] != nil }) ?? inSlot.keys.first,
                  let placement = inSlot[id] else {
                Log.engine.notice("focus \(slotID, privacy: .public): no window in that slot to bring forward")
                continue
            }
            windows.focus(placement.element, pid: placement.info.pid)
        }
        scheduleGlyph()
    }

    var paletteUses: [String: Int] { state.paletteUses }

    /// What Fremspace did to the keyboard's mapping of Caps Lock (the Hyper key). Saved at once:
    /// a crash must not leave a mapping that nothing remembers to remove.
    var hyperMapping: HyperMapping? { state.hyperMapping }

    func rememberHyperMapping(_ record: HyperMapping?) {
        guard record != state.hyperMapping else { return }
        state.hyperMapping = record
        saveState()
    }

    func notePaletteUse(_ key: String) {
        state.paletteUses[key, default: 0] += 1
        scheduleStateSave()
    }

    // MARK: - For the desktop router

    var activeConfiguration: Configuration? { configuration }
    /// What a display is called: the owner's name in the configuration applied, else macOS's.
    func displayName(_ identity: DisplayIdentity) -> String {
        configuration?.displayName(identity) ?? identity.name
    }
    /// The general setting "no floating windows on layout desktops".
    var noFloating: Bool { config?.noFloating ?? false }
    var floatingApps: Set<String> { Set(config?.floatingApps ?? []) }
    /// The shortcuts the owner changed (general setting).
    var shortcuts: [String: Shortcut] { config?.shortcuts ?? [:] }
    /// The setting "Use Caps Lock as ⌃⌥⌘" (the Hyper key).
    var hyperKey: Bool { config?.hyperKey ?? false }
    /// The general setting "show a desktop's name when it changes".
    var desktopNames: Bool { config?.desktopNames ?? true }
    /// The general setting "hovering the notch shows the map of desktops".
    var notchMap: Bool { config?.notchMap ?? true }
    /// The general setting "window previews".
    var windowPreviews: Bool { config?.windowPreviews ?? false }
    /// A display shows another desktop (the desktop links are up to date when this is called).
    var onDesktopChange: (() -> Void)?
    /// The config file was read again.
    var onConfigChanged: (() -> Void)?
    var activeConfigurationID: UUID? { configuration?.id }

    /// Windows may be sent to other desktops now.
    var mayRoute: Bool { isRunning && !paused && !suspended && !displaysSettling }

    /// The real desktop of a configured desktop, when it is there.
    func realSpace(_ desktop: ConfiguredDesktop) -> SpaceKey? {
        desktopMap.real(desktop.display, configured: desktop.index).map { SpaceKey(display: desktop.display, spaceIndex: $0) }
    }

    /// The configured desktops present now (connected display, desktop found).
    var availableDesktops: Set<ConfiguredDesktop> {
        guard let configuration else { return [] }
        let connected = Set(Displays.connected().map(\.identity))
        var result: Set<ConfiguredDesktop> = []
        for display in configuration.displays where !display.ignored && connected.contains(display.identity) {
            for index in display.spaces.indices where desktopMap.real(display.identity, configured: index) != nil {
                result.insert(ConfiguredDesktop(display: display.identity, index: index))
            }
        }
        return result
    }

    /// A window's identity, read again only when its title changed.
    func identity(of element: AXUIElement, info: WindowInfo) -> WindowIdentity {
        if let cached = identities[info.id], cached.title == info.title { return cached.identity }
        let identity = windows.identity(of: element, info: info)
        identities[info.id] = (info.title, identity)
        return identity
    }

    /// The identity read anew, whatever was read before under the same title (a browser's tabs
    /// come after its title).
    func freshIdentity(of element: AXUIElement, info: WindowInfo) -> WindowIdentity {
        identities[info.id] = nil
        return identity(of: element, info: info)
    }

    func adoptRemembered(_ entry: RememberedPlacement, as id: UInt32) {
        state.remembered.adopt(entry, as: id, idsSince: router.bootTime)
        scheduleStateSave()
    }

    /// Remembers a window on a desktop outside any slot (a command, a hand move that stays).
    func rememberDesktop(_ info: WindowInfo, on desktop: ConfiguredDesktop, frame: CGRect?) {
        guard let configuration else { return }
        let identity = identities[info.id]?.identity
            ?? WindowIdentity(bundleID: info.bundleID, profile: info.profile, document: nil, title: info.title, tabs: [],
                              size: frame?.size ?? .zero)
        state.remembered.record(RememberedPlacement(identity: identity, windowID: info.id, configurationID: configuration.id,
                                                    desktop: desktop, slotID: nil, frame: frame ?? .zero, lastSeen: Date()),
                                idsSince: router.bootTime)
        scheduleStateSave()
    }

    /// Desktops removed or moved in the editor (saved), in order. Removed (`to` nil): their links and
    /// remembered windows go. Moved: the macOS desktops cannot be reordered, so the layout takes the
    /// desktop at its new position and the windows are carried there (owner, 2026-11-10: "my
    /// desktops stay as before"); remembered windows follow their layout. The caller reads the
    /// configuration again right after (`configurationSaved`).
    ///
    /// Added (`linked`): a new desktop, counted last (`index`), put at `to` on the macOS desktop
    /// `linked`, which the configuration did not list. The desktops after it are renumbered and
    /// none changes macOS desktop.
    func desktopsRemoved(_ removed: [(configuration: UUID, display: DisplayIdentity, index: Int, to: Int?, linked: String?)]) {
        guard !removed.isEmpty else { return }
        // Focus is kept by configured position, and positions changed meaning: each Focus follows
        // its desktop to the position it has now, and only the Focus of a removed desktop goes.
        // It used to be dropped on the whole display (owner, 2026-11-13: a test desktop removed
        // took the Focus of another desktop with it). `focus`, by real desktop, is made again
        // from this when the configuration is read.
        for r in removed {
            state.focused = r.to.map {
                focusKept(state.focused, afterMovingDesktop: r.index, to: $0, of: r.display, configuration: r.configuration)
            } ?? focusKept(state.focused, afterRemovingDesktop: r.index, of: r.display, configuration: r.configuration)
        }
        // Per display, the configured positions as they were, in their new order.
        var orders: [String: (display: DisplayIdentity, order: [Int])] = [:]
        for r in removed {
            let key = DesktopLinks.key(configuration: r.configuration, display: r.display)
            if orders[key] == nil, r.configuration == configuration?.id,
               let count = configuration.flatMap({ displaySpec(for: r.display, in: $0) })?.spaces.count {
                orders[key] = (r.display, Array(0..<count))
            }
            if let to = r.to, let uuid = r.linked {
                state.desktopLinks.insertDesktop(configuration: r.configuration, display: r.display, index: to, uuid: uuid)
                state.remembered.moveDesktop(configuration: r.configuration, display: r.display, from: r.index, to: to)
                if var entry = orders[key], (0...entry.order.count).contains(to) {
                    // No position before: it was not there.
                    entry.order.insert(-1, at: to)
                    orders[key] = entry
                }
            } else if let to = r.to {
                state.remembered.moveDesktop(configuration: r.configuration, display: r.display, from: r.index, to: to)
                if var entry = orders[key], entry.order.indices.contains(r.index), entry.order.indices.contains(to) {
                    entry.order.insert(entry.order.remove(at: r.index), at: to)
                    orders[key] = entry
                }
            } else {
                state.desktopLinks.removeDesktop(configuration: r.configuration, display: r.display, index: r.index)
                state.remembered.removeDesktop(configuration: r.configuration, display: r.display, index: r.index)
                if var entry = orders[key], entry.order.indices.contains(r.index) {
                    entry.order.remove(at: r.index)
                    orders[key] = entry
                }
            }
        }
        saveState()
        guard removed.contains(where: { $0.to != nil }) else { return }
        let managed = Spaces.managed()
        let uuids = Dictionary(Displays.connected().map { ($0.identity, $0.uuid) }, uniquingKeysWith: { a, _ in a })
        for (key, entry) in orders {
            guard let uuid = uuids[entry.display],
                  let live = managed.displays.first(where: { $0.uuid == uuid })?.desktopUUIDs else { continue }
            // A tab moved to a position means the desktop Mission Control shows there. Links kept by
            // position say that only while the desktops already go as the tabs do; when they did
            // not (a desktop on a spare one, desktops dragged in Mission Control), a move sent
            // layouts and windows to desktops nobody meant (owner, 2026-11-13: "c'est devenu
            // n'importe quoi"). So the links are put in Mission Control's order first.
            if let aligned = alignedLinks(configured: entry.order.count, links: state.desktopLinks.links[key] ?? [], live: live) {
                state.desktopLinks.links[key] = aligned
                saveState()
            }
            let after = resolveDesktops(configured: entry.order.count, links: state.desktopLinks.links[key] ?? [], live: live).real
            // Real position before → real position after, for each desktop that changes place.
            var carry: [Int: Int] = [:]
            for (position, original) in entry.order.enumerated() where original >= 0 {
                guard let from = desktopMap.real(entry.display, configured: original), let to = after[position], from != to else { continue }
                carry[from] = to
            }
            carryWindows(on: entry.display, carry)
        }
    }

    /// Sends every window of the desktops of `display` in `carry` (real positions) to the desktop
    /// given for it. Nothing else moves windows meanwhile; then everything is sorted again.
    private func carryWindows(on display: DisplayIdentity, _ carry: [Int: Int]) {
        guard !carry.isEmpty, SpaceMover.isPresent else { return }
        let managed = Spaces.managed()
        let displays = Displays.connected()
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var sends: [(id: UInt32, sid: UInt64)] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value != getpid(),
                  !drawers.isMember(id),
                  let place = Spaces.spaceIndex(ofWindow: id, managed: managed, displays: displays), place.display == display,
                  let to = carry[place.spaceIndex], let sid = Spaces.spaceID(display: display, real: to) else { continue }
            sends.append((id, sid))
        }
        guard !sends.isEmpty else { return }
        Log.engine.notice("desktops of \(display.name, privacy: .public) reordered: carrying \(sends.count) windows")
        suspended = true
        var waiting = sends.count
        for send in sends {
            SpaceMover.send(send.id, toSpace: send.sid) { [weak self] _ in
                waiting -= 1
                guard waiting == 0, let self else { return }
                self.suspended = false
                // The windows changed desktop with their layout: none of them was moved by hand.
                self.router.reset()
                self.resetPlacements()
                self.scheduleApply()
                self.router.sortAll(reason: .reapply)
            }
        }
    }

    /// The router recognised windows: a pass records those that stay.
    func scheduleApplyFromRouter() {
        scheduleApply()
    }

    func recordSend(success: Bool) {
        moverHealth.record(success: success)
    }

    /// A window reached another desktop: it left its slot here; it is placed when its desktop shows.
    func windowSent(_ id: UInt32) {
        placements[id] = nil
        lockGuard.forget(id: id)
        chosenSlot[id] = nil
        cannotFit.remove(id)
        waitingForMouseUp.remove(id)
        scheduleApply()
    }

    var configStore: ConfigStore { store }

    /// The owner saved the configuration (editor, Lock on this desktop): it applies at once, windows
    /// that no longer belong where they are included (like ⌃⌥⌘R, without ending releases).
    func configurationSaved() {
        reloadConfig()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.router.sortAll(reason: .reapply) }
    }

    /// The browser profiles Fremspace has seen for an app: in the titles of its open windows, in
    /// remembered windows and in the configuration's rules (Brave's own list is in a file macOS
    /// protects).
    func knownProfiles(bundleID: String) -> [String] {
        var profiles = Set<String>()
        for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID) {
            for element in windows.windowElements(pid: app.processIdentifier) {
                if let profile = windows.info(for: element, pid: app.processIdentifier, bundleID: bundleID)?.profile {
                    profiles.insert(profile)
                }
            }
        }
        for entry in state.remembered.entries where entry.identity.bundleID == bundleID {
            if let profile = entry.identity.profile { profiles.insert(profile) }
        }
        for configuration in config?.configurations ?? [] {
            for display in configuration.displays {
                for space in display.spaces {
                    for slot in space.layout?.slots ?? [] {
                        for rule in slot.rules where rule.bundleID == bundleID {
                            if let profile = rule.profile { profiles.insert(profile) }
                        }
                    }
                }
            }
        }
        return profiles.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Fremspace's own state, for "Copy diagnostics".
    func diagnostics() -> String {
        var lines = ["Fremspace state:", "  status: \(status)",
                     "  moving windows between desktops: \(moverHealth.isPresent ? (moverHealth.isAvailable ? "available" : "failing") : "missing")",
                     "  private calls missing: \(missingCalls.isEmpty ? "none" : missingCalls.map(\.rawValue).joined(separator: ", "))",
                     "  placements:"]
        for (id, p) in placements.sorted(by: { $0.key < $1.key }) {
            lines.append("    \(id) \(p.info.bundleID) in \(p.slotID) of \(p.space.display.name) desktop \(p.space.spaceIndex + 1)\(p.locked ? " (locked)" : "")")
        }
        lines.append("  released: \(lockGuard.releasedIDs.sorted())")
        lines.append("  cannot fit: \(cannotFit.sorted())")
        lines.append("  drawer members: \(drawers.memberIDs.sorted())")
        lines.append("  desktop links:")
        for (key, links) in state.desktopLinks.links.sorted(by: { $0.key < $1.key }) {
            lines.append("    \(key): \(links.map { $0 ?? "-" })")
        }
        lines.append("  remembered (\(state.remembered.entries.count)):")
        for e in state.remembered.entries.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            lines.append("    \(e.windowID) \(e.identity.bundleID)\(e.identity.profile.map { " (\($0))" } ?? "") \(e.identity.tabs.count) tabs → \(e.desktop.display.name) desktop \(e.desktop.index + 1)\(e.slotID.map { " slot \($0)" } ?? ""), seen \(e.lastSeen)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// The slot a window holds, if any.
    func slot(of id: UInt32) -> (space: SpaceKey, slotID: String)? {
        placements[id].map { ($0.space, $0.slotID) }
    }

    /// The slot a window is in, or will be in: the one it holds, else the one Fremspace remembers
    /// for it on that desktop, else the first slot of the layout that takes its app. After a
    /// restart Fremspace has only placed the windows of the desktops shown since: the maps would
    /// otherwise draw the windows of every other desktop as outside the slots.
    func likelySlot(of id: UInt32, bundleID: String, on desktop: ConfiguredDesktop, layout: Layout) -> String? {
        if let held = placements[id] { return held.slotID }
        if let remembered = router.rememberedSlot(id, on: desktop), layout.slots.contains(where: { $0.id == remembered }) {
            return remembered
        }
        return layout.slots.first { $0.rules.contains { $0.bundleID == bundleID } }?.id
    }

    /// A released window (quick resize) is managed again (it was just locked somewhere).
    func unrelease(_ id: UInt32) {
        lockGuard.forget(id: id)
    }

    /// A command moved this window (a quick resize): it leaves its slot and floats until ⌃⌥⌘R.
    func moveByCommand(_ id: UInt32, _ element: AXUIElement, to frame: CGRect) {
        if placements[id] != nil {
            lockGuard.release(id)
            placements[id] = nil
            chosenSlot[id] = nil
            cannotFit.remove(id)
            waitingForMouseUp.remove(id)
            Log.engine.info("window \(id) left its slot (quick resize); floats until re-apply")
        }
        setFrame(id, element, frame)
    }

    // MARK: - Desktop links

    /// Rebuilds the configured ↔ real desktop map from the live Spaces, and saves new links.
    private func refreshDesktopMap(_ managed: ManagedSpaces = Spaces.managed()) {
        guard let configuration else {
            if desktopMap != DesktopMap() { router.reset() }
            desktopMap = DesktopMap()
            rebuildFocus()
            return
        }
        let live = liveDesktops(managed)
        var links = state.desktopLinks
        let previous = desktopMap
        desktopMap = DesktopMap(configuration: configuration, live: live, links: &links)
        // Configured desktops changed meaning (a desktop added or removed, a relink): windows that
        // did not move must not look moved by hand, and Focus goes where its desktops went.
        if desktopMap != previous {
            router.reset()
            rebuildFocus()
            memory.removeAll()
        }
        if links != state.desktopLinks {
            state.desktopLinks = links
            saveState()
        }
    }

    /// Connected display → the uuids of its desktops, in Mission Control order.
    private func liveDesktops(_ managed: ManagedSpaces) -> [DisplayIdentity: [String]] {
        let byUUID = Dictionary(Displays.connected().map { ($0.uuid, $0.identity) }, uniquingKeysWith: { a, _ in a })
        var live: [DisplayIdentity: [String]] = [:]
        for display in managed.displays {
            if let identity = byUUID[display.uuid] { live[identity] = display.desktopUUIDs }
        }
        return live
    }

    private func saveState() {
        do {
            try stateStore.save(state)
        } catch {
            Log.engine.error("saving state failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// The real position of a configured desktop: through the links for the active configuration,
    /// by position for another one.
    func realDesktop(configuration id: UUID, display: DisplayIdentity, configured: Int) -> Int? {
        guard let configuration, configuration.id == id else { return configured }
        return desktopMap.real(display, configured: configured)
    }

    /// For "This desktop is…": the display under the mouse, its configured desktops, which of them the
    /// shown desktop is now, and the shown desktop's uuid (empty for the first desktop of the main
    /// display, which is matched by position).
    func shownDesktop() -> (display: DisplayIdentity, labels: [String], current: Int?, uuid: String)? {
        guard let configuration, let point = Displays.mouseAX(),
              let display = Displays.connected().first(where: { $0.frameAX.contains(point) }),
              let spec = displaySpec(for: display.identity, in: configuration),
              let live = Spaces.managed().displays.first(where: { $0.uuid == display.uuid }),
              let currentID = live.current, let real = live.desktops.firstIndex(of: currentID),
              real < live.desktopUUIDs.count else { return nil }
        return (display.identity, spec.spaces.map(\.label), desktopMap.configured(display.identity, real: real),
                live.desktopUUIDs[real])
    }

    /// Ties the shown desktop (`uuid`) to configured desktop `configured`, then places again.
    func linkShownDesktop(display: DisplayIdentity, uuid: String, to configured: Int) {
        guard let configuration, !uuid.isEmpty else { return }
        state.desktopLinks.link(configuration: configuration.id, display: display, configured: configured, to: uuid)
        saveState()
        refreshDesktopMap()
        Log.engine.notice("desktop \(uuid, privacy: .public) of \(display.name, privacy: .public) linked to configured desktop \(configured + 1)")
        drawers.reconcile()
        resetPlacements()
        scheduleApply()
    }

    /// Gives the keyboard to the frontmost placed window of a desktop's layout. A free desktop has
    /// none: there it goes to the window in front that is in no drawer, so that it never stays on
    /// a window parked off screen.
    private func focusMainLayout(_ space: SpaceKey) {
        let order = AXWindows.onScreenWindowOrder()
        let placed = placements.filter { $0.value.space == space }
        if let id = order.first(where: { placed[$0] != nil }), let placement = placed[id] {
            windows.focus(placement.element, pid: placement.info.pid)
            return
        }
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for info in list where (info[kCGWindowLayer as String] as? Int) == 0 {
            guard let id = (info[kCGWindowNumber as String] as? NSNumber)?.uint32Value, !drawers.isMember(id),
                  let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, pid != getpid(),
                  Spaces.spaceIndex(ofWindow: id) == space,
                  let element = windows.windowElements(pid: pid).first(where: { AXWindows.windowID($0) == id }) else { continue }
            windows.focus(element, pid: pid)
            return
        }
    }

    func start() {
        // A timeout on the system-wide element is the default for every AX call, window elements
        // included (a timeout set on an app element covers only that element).
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), AXWindows.messagingTimeout)
        if !missingCalls.isEmpty {
            Log.engine.error("private calls missing on this macOS: \(self.missingCalls.map(\.rawValue).joined(separator: ", "), privacy: .public)")
        }
        keepFrontmostThroughStartup()
        reloadConfig()
        restoreSplits()
        drawers.recoverAfterCrash()
        if AXIsProcessTrusted() {
            drawers.rejoin(state.drawerMembers, takenOut: state.takenOutOfDrawers)
            retryDrawerMembers(after: [2, 5, 15, 40])
        }
        observer.onEvent = { [weak self] event in self?.handle(event) }
        screenToken = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.screensChanged()
        }
        knownDisplays = Self.displayAreas()
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification] {
            sleepTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.asleep = true
            })
        }
        for name in [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification] {
            sleepTokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.asleep = false
                self.lastWake = Date()
                // A change of displays seen while asleep was waiting for this.
                if self.displaysSettling { self.screensChanged() }
            })
        }
        // While the session is locked no app shows its windows: what start could not read is read
        // when the owner is back (seen 2026-11-10: a start behind the lock screen sorted 0 windows
        // and forgot who was in the drawers).
        startedLocked = Self.sessionIsLocked
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"),
                                                            object: nil, queue: .main) { [weak self] _ in
            // The desktop takes a moment to be back behind the lock screen.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self?.sessionUnlocked() }
        }
        if AXIsProcessTrusted() {
            observer.start()
            scheduleApply()
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, !self.startedLocked else { return }
                self.loginRestorer.startup()
            }
        } else {
            // Without Accessibility nothing can be read or moved: stay free, and start as soon as
            // the user grants it.
            waitForTrust(startObserver: true)
        }
        refreshStatus()
    }

    /// macOS says the screens changed (or the Mac woke while they were changing).
    private func screensChanged() {
        let now = Self.displayAreas()
        if !displaysSettling {
            switch displaysChange(from: knownDisplays, to: now) {
            case .none:
                return
            case .visibleArea:
                // The Dock or a menu bar took or gave room: the slots have other frames, and the
                // open drawers too. The closed ones stay parked.
                knownDisplays = now
                Log.engine.notice("the room left by the Dock or the menu bar changed on a display: layouts re-applied")
                resetPlacements()
                scheduleApply()
                drawers.visibleAreaChanged()
                return
            case .displays:
                displaysSettling = true
            }
        }
        let waking = asleep || Date().timeIntervalSince(lastWake) < Self.wakeTime
        let delay = displaySettleDelay(before: knownDisplays, now: now, waking: waking)
        Log.engine.notice("the displays are changing (\(now.count) connected\(waking ? ", the Mac is waking" : "", privacy: .public)): nothing moves until they hold still for \(delay, format: .fixed(precision: 1)) s")
        settleRound += 1
        let round = settleRound
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, round == self.settleRound else { return }
            self.displaysHeldStill()
        }
    }

    /// The displays stopped changing. The same ones as before (the Mac woke up, a display blinked):
    /// macOS moved windows about while some were away, so the drawers go back as they were and
    /// every window is sorted again (owner, 2026-11-14: after a wake the drawers were out and
    /// browser windows sat on another display until ⌃⌥⌘R). Other displays: another desk.
    private func displaysHeldStill() {
        // Asleep the displays may come and go, and behind the lock screen no window can be read:
        // the wake and the unlock come back here.
        guard !asleep, !Self.sessionIsLocked else {
            displaysOwed = true
            return
        }
        displaysOwed = false
        displaysSettling = false
        let now = Self.displayAreas()
        let returned = displaysChange(from: knownDisplays, to: now) != .displays
        knownDisplays = now
        if returned {
            Log.engine.notice("the displays are back as they were (\(now.count) connected): drawers put back, windows sorted again")
        } else {
            // Every placement may point at a display that is gone, and no drawer member may
            // stay parked.
            Log.engine.notice("the displays changed (\(now.count) connected): drawer members back on screen, configuration chosen again")
            drawers.restoreAll()
        }
        resetPlacements()
        chooseConfiguration()
        if returned { drawers.displaysReturned() }
        // macOS put the windows where they are: none of them was moved by hand.
        router.reset()
        scheduleApply()
        router.sortAll(reason: .reapply)
    }

    /// A drawer window that could not be read at start (its app was busy, the Mac loaded, its
    /// desktop not shown) stayed out of its drawer for good unless the session had been locked:
    /// in sight on one desktop, following nothing (owner, 2026-11-12, the left drawer after
    /// restarts). It is read again after each of `delays`, and whenever a display changes desktop.
    private func retryDrawerMembers(after delays: [TimeInterval]) {
        guard let delay = delays.first else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.drawers.hasWaitingMembers else { return }
            // Behind the lock screen nothing is readable: the unlock reads them.
            if AXIsProcessTrusted(), !Self.sessionIsLocked { self.drawers.retryRejoin() }
            self.retryDrawerMembers(after: Array(delays.dropFirst()))
        }
    }

    /// Fremspace started behind the lock screen: its startup pass waits for the owner.
    private var startedLocked = false

    static var sessionIsLocked: Bool {
        (CGSessionCopyCurrentDictionary() as? [String: Any])?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }

    /// When what start could not read was last tried again.
    private var lastUnlockTry = Date.distantPast

    private func sessionUnlocked() {
        guard AXIsProcessTrusted() else { return }
        lastUnlockTry = Date()
        let waiting = drawers.hasWaitingMembers
        drawers.retryRejoin()
        if startedLocked {
            startedLocked = false
            Log.engine.notice("session unlocked: the startup pass runs now")
            loginRestorer.startup()
        } else if waiting {
            scheduleApply()
        }
        if displaysOwed { displaysHeldStill() }
    }

    /// Polls until Accessibility is granted (again), then resumes. `startObserver`: first grant at
    /// launch; a grant revoked while running keeps the observer it already has.
    private func waitForTrust(startObserver: Bool) {
        guard trustTimer == nil else { return }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] timer in
            guard AXIsProcessTrusted(), let self else { return }
            timer.invalidate()
            self.trustTimer = nil
            self.refreshStatus()
            self.scheduleApply()
            if startObserver {
                // The launch itself was waiting for the grant: what a trusted launch does comes now
                // (the startup sort, or the restore at login).
                self.observer.start()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in self?.loginRestorer.startup() }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        trustTimer = timer
    }

    /// Reads the configuration file again. On error the engine is free and says why; the file is
    /// never written.
    func reloadConfig() {
        let before = config
        do {
            config = try store.load()
            loadError = nil
        } catch let error as ConfigError {
            config = nil
            switch error {
            case .newerVersion(let v):
                loadError = "Config file is version \(v), newer than this Fremspace"
            case .corrupt(let why):
                loadError = "Config file unreadable: \(why)"
            case .changedOnDisk:
                loadError = "Config file changed while it was read"
            }
        } catch {
            config = nil
            loadError = "Config file unreadable: \(error.localizedDescription)"
        }
        resetPlacements()
        memory.removeAll()
        chooseConfiguration()
        drawers.reconcile()
        // An app that just got a slot: its windows kept in a drawer by hand go to the slot (owner,
        // 2026-11-13: the slot was saved and nothing moved, the window sat in a drawer).
        if let before, let config, let id = configuration?.id {
            let apps = appsGivenASlot(before: before, after: config, configuration: id)
            drawers.release(apps: apps)
            // And those that sit on a free desktop, at the sort that follows the save.
            router.givenASlot.formUnion(apps)
        }
        scheduleApply()
        onConfigChanged?()
    }

    private func resetPlacements() {
        for id in placements.keys { lockGuard.forget(id: id) }
        placements.removeAll()
        // Every window is placed anew: nothing is left to force.
        refocused.removeAll()
        cannotFit.removeAll()
        waitingForMouseUp.removeAll()
    }

    private var isRunning: Bool {
        if case .running = status { return true }
        return false
    }

    /// Puts every window of the current Spaces back in its slot. An explicit request, so it also
    /// ends a pause.
    func reapplyCurrentSpaces() {
        paused = false
        if lockGuard.releasedCount > 0 {
            Log.engine.notice("re-apply: \(self.lockGuard.releasedCount) released windows managed again")
        }
        lockGuard.endReleases()
        apply(force: true)
        // Sends that macOS refused are tried again: the Status page says this command does.
        if moverHealth.isPresent, !moverHealth.isAvailable {
            Log.engine.notice("re-apply: sending windows to another desktop is tried again")
        }
        moverHealth.retry()
        router.sortAll(reason: .reapply)
    }

    /// Toggles Focus on the Space of the focused window: the slot of that window when it is
    /// focusable, else the Space's default Focus slot. The focused slot's window comes to the front.
    func toggleFocusOnFrontmostSpace() {
        guard !paused, let configuration,
              let element = windows.focusedWindow(), let id = AXWindows.windowID(element),
              let space = Spaces.spaceIndex(ofWindow: id),
              displaySpec(for: space.display, in: configuration) != nil,
              let spec = configuredSpec(space) else {
            NSSound.beep()
            return
        }
        let frontmostSlot = placements[id].flatMap { $0.space == space ? $0.slotID : nil }
        guard let target = focusTarget(in: spec, frontmostSlot: frontmostSlot) else {
            NSSound.beep()
            return
        }
        let focused = focus.toggle(space, slot: target)
        rememberFocus()
        Log.engine.info("focus \(focused ?? "off", privacy: .public) on \(spec.label, privacy: .public)")
        apply(force: true, only: space)
        scheduleGlyph()
        guard let focused else { return }
        // Bring the focused slot forward and give it the keyboard: the frontmost window when it is in
        // that slot, else the first window placed there.
        let inSlot = placements.filter { $0.value.space == space && $0.value.slotID == focused }
        if let placement = inSlot[id] ?? inSlot.values.first {
            windows.focus(placement.element, pid: placement.info.pid)
        }
    }

    /// Saves which slots are in Focus (of the active configuration; those of the others, and of
    /// its desktops that are not there now, are kept).
    private func rememberFocus() {
        guard let configuration else { return }
        let focused = focusToKeep(focus, kept: state.focused, configurationID: configuration.id,
                                  configured: { self.configuredDesktop($0) }, real: { self.realSpace($0) })
        guard focused != state.focused else { return }
        state.focused = focused
        scheduleStateSave()
    }

    /// Keeps who is in which drawer, so that a restart finds the drawers as they were.
    private func rememberDrawers() {
        let membership = drawers.membership
        guard membership.members != state.drawerMembers || membership.takenOut != state.takenOutOfDrawers else { return }
        state.drawerMembers = membership.members
        state.takenOutOfDrawers = membership.takenOut
        scheduleStateSave()
    }

    /// At start: the pairs that were side by side when Fremspace stopped are again, when both
    /// windows still exist. The placement pass does the rest.
    private func restoreSplits() {
        guard !state.splits.isEmpty else { return }
        var alive: [UInt32: Int32] = [:]
        for info in CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? [] {
            if let id = info[kCGWindowNumber as String] as? UInt32, let pid = info[kCGWindowOwnerPID as String] as? Int32 {
                alive[id] = pid
            }
        }
        splits = splitSides(state.splits, alive: alive)
        splitPids = Dictionary(uniqueKeysWithValues: splits.keys.compactMap { id in alive[id].map { (id, $0) } })
        Log.engine.info("split: \(self.splits.count / 2) of \(self.state.splits.count) pairs found again")
        rememberSplits()
    }

    /// Saves the pairs side by side.
    private func rememberSplits() {
        let saved = savedSplits(splits, pids: splitPids)
        guard saved != state.splits else { return }
        state.splits = saved
        scheduleStateSave()
    }

    /// Focus is kept by configured desktop (`state.focused`); `focus` is the same by the desktop
    /// that shows each now. It is made again whenever the two can have come apart: at start (the
    /// slots in Focus when Fremspace stopped are in Focus again), when the configuration is read
    /// or another one applies, and when the desktops are reordered, added or removed. Kept by
    /// position, a Focus stayed on whatever desktop took that position, and was then saved there.
    private func rebuildFocus() {
        let before = focus.all
        if let configuration {
            focus = focusState(from: state.focused, configurationID: configuration.id, real: { self.realSpace($0) }) { desktop, slotID in
                guard let display = displaySpec(for: desktop.display, in: configuration),
                      display.spaces.indices.contains(desktop.index) else { return false }
                return display.spaces[desktop.index].layout?.slots.contains { $0.id == slotID } ?? false
            }
        } else {
            focus = FocusState()
        }
        let after = focus.all
        let changed = Set(before.keys).union(after.keys).filter { before[$0] != after[$0] }
        guard !changed.isEmpty else { return }
        // Their windows take their frames at the next pass, or when the desktop is shown.
        refocused.formUnion(changed)
        Log.engine.info("focus: \(after.count) slots in Focus for the desktops as they are now (\(changed.count) desktops changed)")
    }

    // MARK: - Missing desktops

    /// Displays of the active configuration with fewer desktops than configured.
    var missingDesktops: [MissingDesktops] {
        guard let configuration else { return [] }
        return FremspaceCore.missingDesktops(configuration, present: Desktops.counts())
    }

    /// Adds the missing desktops (Mission Control); false when it could not. Then re-applies.
    func addMissingDesktops() -> Bool {
        // Adding desktops pumps the run loop while Mission Control is open: AX events arrive meanwhile,
        // and no window may move under Mission Control.
        suspended = true
        defer { suspended = false }
        var ok = true
        for missing in missingDesktops {
            guard let display = Displays.connected().first(where: { $0.identity == missing.display }) else { continue }
            ok = Desktops.add(on: display, count: missing.needed - missing.present) && ok
        }
        scheduleApply()
        return ok
    }

    // MARK: - Desktops the configuration does not list

    /// A macOS desktop that the configuration in use does not list: `position` among the desktops
    /// of its display, in Mission Control order, and the uuid that tells it from the others.
    struct UnlistedDesktop: Equatable {
        var position: Int
        var uuid: String
        /// Where a configured desktop that takes it sits among the others, for the tabs to go as
        /// Mission Control does.
        var index: Int
    }

    /// What the editor is told about the desktops of the Mac: those the configuration in use does
    /// not list, and the displays whose desktops Mission Control shows in another order.
    struct DesktopsOnTheMac: Equatable {
        var unlisted: [DisplayIdentity: [UnlistedDesktop]] = [:]
        /// Display → its configured desktops in Mission Control's order.
        var order: [DisplayIdentity: [Int]] = [:]
    }

    /// The macOS desktops that the configuration in use does not list, per display: what a desktop
    /// removed in the editor leaves behind. Read from the Spaces as they are now, with a map of its
    /// own: the engine's is rebuilt at its next pass, too late for the editor right after a save.
    /// The first desktop of the main display has no uuid and is left out: nothing could check
    /// afterwards that it is the one that went.
    func unlistedDesktops() -> [DisplayIdentity: [UnlistedDesktop]] { desktopsOnTheMac().unlisted }

    func desktopsOnTheMac() -> DesktopsOnTheMac {
        guard let configuration else { return DesktopsOnTheMac() }
        let live = liveDesktops(Spaces.managed())
        // Links found on the way are not kept: this only reads.
        var links = state.desktopLinks
        let map = DesktopMap(configuration: configuration, live: live, links: &links)
        var result = DesktopsOnTheMac()
        for spec in configuration.displays where !spec.ignored {
            guard let uuids = live[spec.identity] else { continue }
            let unlisted = map.unconfigured(spec.identity, live: uuids.count)
                .filter { !uuids[$0].isEmpty }
                .map { UnlistedDesktop(position: $0, uuid: uuids[$0], index: map.rank(spec.identity, real: $0)) }
            if !unlisted.isEmpty { result.unlisted[spec.identity] = unlisted }
            if let order = map.missionControlOrder(spec.identity) { result.order[spec.identity] = order }
        }
        return result
    }

    /// Puts the configured desktops of `display` in Mission Control's order, over the macOS desktops
    /// they use: each layout takes the desktop at its tab's position and its windows are carried
    /// there. The desktops themselves do not move. False when there was nothing to do, or when it
    /// cannot be done for sure (`alignedLinks`).
    func alignDesktops(on display: DisplayIdentity) -> Bool {
        guard let configuration, let spec = displaySpec(for: display, in: configuration),
              let live = liveDesktops(Spaces.managed())[display] else { return false }
        let key = DesktopLinks.key(configuration: configuration.id, display: display)
        let links = state.desktopLinks.links[key] ?? []
        guard let aligned = alignedLinks(configured: spec.spaces.count, links: links, live: live) else { return false }
        let before = resolveDesktops(configured: spec.spaces.count, links: links, live: live).real
        let after = resolveDesktops(configured: spec.spaces.count, links: aligned, live: live).real
        state.desktopLinks.links[key] = aligned
        saveState()
        var carry: [Int: Int] = [:]
        for (from, to) in zip(before, after) {
            if let from, let to, from != to { carry[from] = to }
        }
        Log.engine.notice("desktops of \(display.name, privacy: .public) put in Mission Control's order: \(carry.count) change desktop")
        refreshDesktopMap()
        carryWindows(on: display, carry)
        scheduleApply()
        return true
    }

    /// Removes from the Mac the unlisted desktop `uuid` of `display` (Mission Control opens); false
    /// when it could not, or when the desktop is no longer unlisted. The owner was asked: macOS
    /// moves its windows to another desktop and nothing undoes it. Then re-applies.
    func removeUnlistedDesktop(on display: DisplayIdentity, uuid: String) -> Bool {
        // Read again: the desktops may have changed since the editor drew its button.
        guard let target = unlistedDesktops()[display]?.first(where: { $0.uuid == uuid }),
              let connected = Displays.connected().first(where: { $0.identity == display }) else { return false }
        // As for adding: no window may move under Mission Control.
        suspended = true
        defer { suspended = false }
        let removed = Desktops.remove(on: connected, position: target.position)
        if removed, liveDesktops(Spaces.managed())[display]?.contains(uuid) == true {
            Log.engine.error("remove desktop: a desktop went and it is not the one asked for")
        }
        Log.engine.info("remove desktop: desktop \(target.position + 1) of a display \(removed ? "removed from the Mac" : "could not be removed", privacy: .public)")
        scheduleApply()
        return removed
    }

    private let stackHUD = StackHUD()

    // MARK: - Menu bar glyph

    /// Called with the glyph to draw, shortly after something that may change it.
    var onGlyphChange: ((MenuGlyph) -> Void)?
    private var glyphScheduled = false

    /// What the menu bar draws: the three slots of the app icon, or the pause mark. It used to draw
    /// the layout of the desktop in front, which changed at every click and, with a slot in Focus,
    /// was one white square (owner, 2026-11-12: "c'est mieux pas vivante").
    var menuGlyph: MenuGlyph { paused ? .paused : .brand }

    /// Events come in bursts, and placements follow them: the glyph is read once things settled.
    private func scheduleGlyph() {
        guard !glyphScheduled, onGlyphChange != nil else { return }
        glyphScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self else { return }
            self.glyphScheduled = false
            self.onGlyphChange?(self.menuGlyph)
        }
    }

    /// Shows the next window stacked in the active window's slot (a layout slot or a drawer slot) and
    /// gives it the keyboard. Beeps when the slot holds no other window.
    func showNextInStack(forward: Bool) {
        guard isRunning, let element = windows.focusedWindow(), let id = AXWindows.windowID(element) else {
            return NSSound.beep()
        }
        var stack: [UInt32: (AXUIElement, pid_t)] = [:]
        if let members = drawers.stack(of: id) {
            stack = members
        } else if let placement = placements[id] {
            for (other, p) in placements where p.space == placement.space && p.slotID == placement.slotID {
                stack[other] = (p.element, p.info.pid)
            }
            // A window that is gone without a word (a browser tab merged into another window) or is
            // on another desktop now would be asked to come forward, would not, and the round would
            // stop on it instead of going back to the first.
            for other in stack.keys where other != id {
                if Spaces.spaceIDs(ofWindow: other).isEmpty {
                    Log.engine.notice("stack: window \(other) of \(placement.slotID, privacy: .public) is gone; forgotten")
                    stack[other] = nil
                    forget(other)
                } else if Spaces.spaceIndex(ofWindow: other) != placement.space {
                    stack[other] = nil
                }
            }
        }
        // A minimised window does not come forward either: the round goes past it.
        for (other, entry) in stack where other != id {
            var minimized: CFTypeRef?
            if AXUIElementCopyAttributeValue(entry.0, kAXMinimizedAttribute as CFString, &minimized) == .success,
               (minimized as? Bool) == true {
                stack[other] = nil
            }
        }
        guard let next = nextInStack(Array(stack.keys), after: id, forward: forward), let (target, pid) = stack[next] else {
            return NSSound.beep()
        }
        windows.focus(target, pid: pid)
        // Which one of how many: the owner goes through them without seeing the others.
        let order = Set(stack.keys).sorted()
        if let index = order.firstIndex(of: next), let frame = windows.frame(target) ?? windows.frame(element) {
            var value: CFTypeRef?
            AXUIElementCopyAttributeValue(target, kAXTitleAttribute as CFString, &value)
            stackHUD.show(count: order.count, index: index, title: value as? String ?? "",
                          icon: NSRunningApplication(processIdentifier: pid)?.icon, over: frame)
        }
    }

    /// Starting moves windows and may bring some forward: the window that had the keyboard gets it
    /// back, unless the owner clicked meanwhile.
    private func keepFrontmostThroughStartup() {
        guard let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() else { return }
        let window = windows.focusedWindow()
        let id = window.flatMap(AXWindows.windowID)
        let started = Date()
        for delay in [1.0, 2.5, 4.0] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self else { return }
                // Only a click says the owner went elsewhere: keys typed meanwhile were meant for the
                // window that had the keyboard.
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: .leftMouseDown)
                guard idle > Date().timeIntervalSince(started) else { return }
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                let now = self.windows.focusedWindow().flatMap(AXWindows.windowID)
                guard front != app.processIdentifier || now != id else { return }
                if let window {
                    self.windows.focus(window, pid: app.processIdentifier)
                } else {
                    app.activate()
                }
                Log.engine.info("keyboard given back to \(app.bundleIdentifier ?? "?", privacy: .public) after startup")
            }
        }
    }

    /// Gives the keyboard to the window of the nearest region on that side of the active window's:
    /// layout slots and the slots of open drawers (a layout slot mostly under an open drawer is
    /// skipped). Beeps when there is none. Then the Focus hotkey can enlarge a layout slot.
    func activateNeighbourSlot(_ direction: Direction) {
        guard isRunning, let element = windows.focusedWindow(), let id = AXWindows.windowID(element) else {
            NSSound.beep()
            return
        }
        let space: SpaceKey, current: String
        if let (home, key) = drawers.region(of: id) {
            (space, current) = (home, key)
        } else if let placement = placements[id] {
            (space, current) = (placement.space, placement.slotID)
        } else {
            NSSound.beep()
            return
        }
        guard let display = Displays.connected().first(where: { $0.identity == space.display }) else { return NSSound.beep() }
        let layoutFrames = spaceSpec(space)?.layout.map {
            slotFrames(layout: $0, focus: focus.slot(space), visible: display.visibleAX, gap: Self.gap)
        } ?? [:]
        let open = drawers.openRegions(space)
        let regions = visibleRegions(layout: layoutFrames, drawers: open.frames, drawerZones: open.zones)
        guard let target = neighbourSlot(from: current, toward: direction, frames: regions) else { return NSSound.beep() }
        if let (targetElement, pid) = open.fronts[target] {
            windows.focus(targetElement, pid: pid)
            return
        }
        let order = AXWindows.onScreenWindowOrder()
        guard let next = order.first(where: { placements[$0]?.space == space && placements[$0]?.slotID == target }),
              let nextPlacement = placements[next] else { return NSSound.beep() }
        windows.focus(nextPlacement.element, pid: nextPlacement.info.pid)
    }

    // MARK: - Status

    private func chooseConfiguration() {
        if let config {
            let connected = Displays.connected().map(\.identity)
            let previous = configuration?.id
            configuration = FremspaceCore.chooseConfiguration(config, connected: connected,
                                                              chosen: state.chosenConfigurations[deskKey(connected)])
            if configuration?.id != previous { router.reset() }
            ambiguous = configuration.flatMap { ambiguousDisplay(connected: connected, in: $0) }
        } else {
            configuration = nil
            ambiguous = nil
        }
        refreshDesktopMap()
        // Also when the desktops are where they were: another configuration, or other layouts.
        rebuildFocus()
        refreshStatus()
    }

    /// The configurations of the saved file that the connected displays allow, in its order.
    var fittingConfigurations: [Configuration] {
        config.map { FremspaceCore.fittingConfigurations($0, connected: Displays.connected().map(\.identity)) } ?? []
    }

    /// The configuration the owner picked for the connected displays, when it is the one in use.
    var chosenConfigurationID: UUID? {
        guard let id = state.chosenConfigurations[deskKey(Displays.connected().map(\.identity))],
              id == configuration?.id else { return nil }
        return id
    }

    /// The owner picks the configuration for the displays connected now (nil: Fremspace picks again
    /// by itself). A command, like Focus: it applies at once and is kept in the state file, the
    /// configuration file is not written. False when the configuration does not fit the displays.
    @discardableResult
    func useConfiguration(_ id: UUID?) -> Bool {
        guard let config else { return false }
        let connected = Displays.connected().map(\.identity)
        if let id {
            guard FremspaceCore.fittingConfigurations(config, connected: connected).contains(where: { $0.id == id }) else { return false }
            state.chosenConfigurations[deskKey(connected)] = id
        } else {
            state.chosenConfigurations[deskKey(connected)] = nil
        }
        saveState()
        let before = configuration?.id
        chooseConfiguration()
        guard configuration?.id != before else {
            onConfigChanged?()
            return true
        }
        Log.engine.notice("configuration \(id == nil ? "left to Fremspace" : "picked by the owner", privacy: .public): \(self.configuration?.name ?? "none", privacy: .public) is in use")
        // As after a save: other layouts, other drawers, and windows that belong elsewhere now.
        resetPlacements()
        memory.removeAll()
        drawers.reconcile()
        scheduleApply()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in self?.router.sortAll(reason: .reapply) }
        onConfigChanged?()
        return true
    }

    private func refreshStatus() {
        if paused {
            status = .paused
        } else if let reason = missingCallsReason(PrivateCalls.missing) {
            // Before anything the owner could fix: only an update of Fremspace does.
            status = .free(reason: reason)
        } else if !AXIsProcessTrusted() {
            status = .free(reason: "Accessibility not granted")
        } else if let loadError {
            status = .free(reason: loadError)
        } else if let ambiguous {
            status = .free(reason: "Two displays report the same identity as \(ambiguous.name)")
        } else if let configuration {
            status = .running(configuration: configuration.name)
        } else {
            status = .free(reason: Self.noConfigurationReason)
        }
    }

    // MARK: - Events

    private func handle(_ event: WindowEvent) {
        // Should the unlock notice not come: the first window event after the lock screen does it.
        if startedLocked || drawers.hasWaitingMembers || displaysOwed, Date().timeIntervalSince(lastUnlockTry) > 10, !Self.sessionIsLocked {
            sessionUnlocked()
        }
        scheduleGlyph()
        // While the displays change, macOS moves windows and desktops about: none of it is the
        // owner's doing, and what it leaves is put right once they hold still. Windows that go are
        // still forgotten.
        if displaysSettling {
            switch event {
            case .destroyed, .appTerminated: break
            default: return
            }
        }
        switch event {
        case .spaceChanged:
            refreshDesktopMap()
            onDesktopChange?()
            drawers.retryRecovery()
            drawers.retryRejoin()
            drawers.desktopChanged()
            closeSceneDrawersLeftBehind()
            drawers.followShownDesktops()
            router.checkHandMoves()
            scheduleApply()
        case .created(let id):
            router.handleAppeared(id)
            calls.check(id)
            scheduleApply()
        case .titleChanged(let id):
            calls.check(id)
        case .appLaunched(let pid):
            router.handleLaunched(pid)
            scheduleApply()
        case .moved(let id), .resized(let id):
            if drawers.isMember(id) {
                drawers.handleFrameChanged(id)
            } else {
                drawers.watchDrop(id)
                router.checkHandMovesAfterDrag()
                frameChanged(id)
                if placements[id] == nil { noteLooseMove(id) }
            }
        case .destroyed(let id):
            forget(id)
            drawers.forget(id)
            router.forget(id)
            calls.forget(id)
            WindowPreviews.shared.forget(id)
        case .appTerminated(let pid):
            for (id, placement) in placements where placement.info.pid == pid {
                forget(id)
            }
            drawers.forgetApp(pid)
            router.forgetApp(pid)
        case .activated(let id):
            guard isRunning else { return }
            calls.check(id)
            router.checkHandMoves()
            let isMain = placements[id].map { $0.space == Spaces.spaceIndex(ofWindow: id) } ?? false
            drawers.handleActivated(id, isMainLayoutWindow: isMain)
        }
    }

    private func forget(_ id: UInt32) {
        if let space = endSplit(id) {
            // The window left alone has its slot whole again.
            DispatchQueue.main.async { [weak self] in
                guard let self, !self.paused else { return }
                self.apply(force: true, only: space)
            }
        }
        identities[id] = nil
        pendingRecords[id] = nil
        looseMoves.remove(id)
        placements[id] = nil
        lockGuard.forget(id: id)
        chosenSlot[id] = nil
        cannotFit.remove(id)
        ownMoves[id] = nil
        failedMoves[id] = nil
        waitingForMouseUp.remove(id)
    }

    /// Coalesces bursts of events (an app opening several windows) into one pass.
    private func scheduleApply() {
        guard !applyScheduled else { return }
        applyScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            guard let self else { return }
            self.applyScheduled = false
            guard !self.paused else { return }
            if NSEvent.pressedMouseButtons & 1 != 0 {
                // Never move windows under a drag (a Brave tab pulled out, a window taken to the
                // screen edge): run the pass once the button is up.
                self.applyAfterMouseUp = true
                self.startMouseTimer()
                return
            }
            self.apply(force: false)
        }
    }

    // MARK: - Placement

    /// `force`: also put back windows of unlocked slots, which are otherwise placed only once and
    /// then left where the user puts them. `only`: limit the pass to one Space (Focus toggles).
    private func apply(force: Bool, only: SpaceKey? = nil) {
        guard !suspended, !displaysSettling else { return }
        guard AXIsProcessTrusted() else {
            // Revoked while running: say so (the menu showed "Running") and resume when granted.
            refreshStatus()
            waitForTrust(startObserver: false)
            return
        }
        guard configuration != nil else { return }
        let managed = Spaces.managed()
        guard !managed.displays.isEmpty else {
            status = .free(reason: missingCallsReason(PrivateCalls.missing) ?? "Cannot read Spaces")
            return
        }
        refreshStatus()
        guard isRunning else { return }
        refreshDesktopMap(managed)
        let displays = Displays.connected()
        let current = Spaces.current()
        var desktops: [SpaceKey: SpaceSpec] = [:]
        var freeDesktops: Set<SpaceKey> = []
        var visibleFrames: [DisplayIdentity: CGRect] = [:]
        for display in displays {
            guard let index = current[display.identity] else { continue }
            let space = SpaceKey(display: display.identity, spaceIndex: index)
            guard let spec = configuredSpec(space) else { continue }
            guard spec.layout != nil else {
                freeDesktops.insert(space)
                continue
            }
            desktops[space] = spec
            visibleFrames[display.identity] = display.visibleAX
        }
        // Released windows and drawer members are not the layout's (their frames are not even read).
        var skip: Set<UInt32> = []
        var seen: [SeenWindow] = []
        // The slot the user dropped each window into, else its remembered slot.
        var chosen = chosenSlot
        var elements: [UInt32: (element: AXUIElement, info: WindowInfo)] = [:]
        let onScreen = windows.windows(onScreen: true)
        completeSplit(onScreen, managed: managed, displays: displays)
        for (info, element) in onScreen {
            let space = Spaces.spaceIndex(ofWindow: info.id, managed: managed, displays: displays)
            // A window of an app with a drawer slot on this display goes to that drawer, unless the
            // layout of the desktop has a slot for it or the owner took it out.
            if let space, let configuration, !drawers.isMember(info.id), !drawers.wasTakenOut(info.id),
               let specs = displaySpec(for: space.display, in: configuration)?.drawers, !specs.isEmpty,
               let slot = drawerSlotKey(for: info, in: specs, layout: desktops[space]?.layout) {
                drawers.adopt(element, info, display: space.display, slot: slot)
            }
            // A fixed-size window sent to a free desktop ("no floating windows"): from another display
            // it lands mostly off screen, so it is centred like any other arrival.
            if let space, freeDesktops.contains(space), !info.isManageable, info.canChangeDesktop,
               router.pendingArrival[info.id] != nil, let frame = windows.frame(element) {
                _ = placeArrival(info.id, element, space: space, frame: frame)
            }
            if let space, freeDesktops.contains(space), info.isManageable, !drawers.isMember(info.id),
               var frame = windows.frame(element) {
                if let desktop = configuredDesktop(space) { router.saw(info, on: desktop) }
                if let placed = placeArrival(info.id, element, space: space, frame: frame) { frame = placed }
                // A window of a free desktop: remembered there (restored there after a reboot),
                // unless its place is a slot elsewhere and nobody moved it (see `keepsItsSlot`).
                let keepsSlot = configuration.flatMap { configuration in
                    configuredDesktop(space).map {
                        state.remembered.keepsItsSlot(window: info.id, configurationID: configuration.id, awayFrom: $0,
                                                      idsSince: router.bootTime)
                    }
                } ?? false
                if !keepsSlot { remember(element, info, space: space, slotID: nil, frame: frame) }
            }
            guard let space, desktops[space] != nil else { continue }
            if lockGuard.isReleased(info.id) || drawers.isMember(info.id) {
                skip.insert(info.id)
                continue
            }
            seen.append(SeenWindow(info: info, space: space, frame: windows.frame(element)))
            elements[info.id] = (element, info)
            if let desktop = configuredDesktop(space) {
                router.saw(info, on: desktop)
                if chosen[info.id] == nil, let slot = router.rememberedSlot(info.id, on: desktop) { chosen[info.id] = slot }
            }
        }
        let plan = planPlacements(PlanInput(
            desktops: desktops, visible: visibleFrames, windows: seen,
            held: placements.mapValues { HeldSlot(space: $0.space, slotID: $0.slotID) },
            chosen: chosen, memory: memory, skip: skip, cannotFit: cannotFit,
            focus: Dictionary(uniqueKeysWithValues: desktops.keys.compactMap { key in focus.slot(key).map { (key, $0) } }),
            force: force, only: only, gap: Self.gap, tolerance: lockGuard.tolerance, split: splits, refocused: refocused))
        for space in desktops.keys where only == nil || only == space { refocused.remove(space) }
        var moves: [UInt32: PlannedPlacement] = [:]
        func hold(_ planned: PlannedPlacement, _ element: AXUIElement, _ info: WindowInfo) {
            placements[planned.id] = Placement(element: element, info: info, space: planned.space,
                                               slotID: planned.slotID, frame: planned.frame, locked: planned.locked)
        }
        for planned in plan {
            guard let (element, info) = elements[planned.id] else { continue }
            remember(element, info, space: planned.space, slotID: planned.slotID, frame: planned.frame)
            // A window that has to move holds its slot once it has moved: held before, a refused
            // move into an unlocked slot was never tried again.
            if planned.move != nil { moves[planned.id] = planned } else { hold(planned, element, info) }
        }
        // Stacked windows are resized in an order that keeps the front one covering the others.
        for id in placementOrder(moves.values.compactMap(\.move), frontToBack: AXWindows.onScreenWindowOrder()) {
            guard let planned = moves[id], let move = planned.move, let (element, info) = elements[id] else { continue }
            guard setFrame(id, element, move.to) else {
                let failures = (failedMoves[id] ?? 0) + 1
                switch moveRetry(failures: failures) {
                case .again(let delay):
                    failedMoves[id] = failures
                    // Also a slot it held before (a forced pass): the next pass plans the move again.
                    placements[id] = nil
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.scheduleApply() }
                case .giveUp:
                    // The count stays until a move succeeds: a locked slot's window is tried at
                    // every pass as before, without a pass of its own each time.
                    failedMoves[id] = failures
                    hold(planned, element, info)
                    if moveRetry(failures: failures - 1) != .giveUp {
                        Log.engine.notice("window \(id) \(info.bundleID, privacy: .public) could not be moved into \(planned.slotID, privacy: .public) after \(failures) tries; left where it is")
                    }
                }
                continue
            }
            failedMoves[id] = nil
            hold(planned, element, info)
            Log.engine.info("placed \(id) \(info.bundleID, privacy: .public) in \(planned.slotID, privacy: .public) of \(desktops[planned.space]?.label ?? "?", privacy: .public)")
            checkFit(info, element, move.to, slotID: planned.slotID)
        }
        let plannedIDs = Set(plan.map(\.id))
        for planned in plan {
            router.arrived(planned.id)
            if let desktop = configuredDesktop(planned.space) { router.placed(planned.id, in: planned.slotID, on: desktop) }
        }
        // Sent windows on a layout desktop where they have no slot (a command): their own frame.
        for window in seen where !plannedIDs.contains(window.info.id) {
            if let element = elements[window.info.id]?.element, let space = window.space, let frame = window.frame {
                _ = placeArrival(window.info.id, element, space: space, frame: frame)
            }
        }
        for (space, spec) in desktops where spec.unmatched != .float {
            if let only, only != space { continue }
            let unmatched = seen.contains { $0.space == space && $0.info.isManageable && !plannedIDs.contains($0.info.id) }
            if unmatched, unsupportedPolicyLogged.insert(spec.label).inserted {
                Log.engine.notice("unmatched policy of \(spec.label, privacy: .public) not yet supported; windows float")
            }
        }
    }

    // MARK: - Side by side

    /// Opens a second window of the app in front and puts the two side by side: in the window's
    /// slot when it has one, else on the two halves of its display. On a window that is side by
    /// side already: back to one over the other. For the occasional need of two browser windows
    /// next to each other, on whatever display and profile.
    func splitWithNewWindow() {
        guard isRunning, !paused, let element = windows.focusedWindow(), let id = AXWindows.windowID(element),
              let app = NSWorkspace.shared.frontmostApplication else { return NSSound.beep() }
        if splits[id] != nil {
            let space = endSplit(id)
            Log.engine.info("split: window \(id) and its neighbour stack again")
            if let space { apply(force: true, only: space) }
            return
        }
        let pid = app.processIdentifier
        var known = Set(windows.windowElements(pid: pid).compactMap(AXWindows.windowID))
        known.formUnion(placements.filter { $0.value.info.pid == pid }.keys)
        guard windows.pressNewWindow(pid: pid) else {
            Log.engine.notice("split: \(app.bundleIdentifier ?? "?", privacy: .public) has no New Window item to press")
            return NSSound.beep()
        }
        pendingSplit = (pid, id, known, Date())
        Log.engine.info("split: a second window asked of \(app.bundleIdentifier ?? "?", privacy: .public)")
        // The window's arrival runs a pass; these are for an app that is slow to say so.
        for delay in [0.5, 1.2, 2.5] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pendingSplit != nil else { return }
                self.scheduleApply()
            }
        }
    }

    /// The second window asked for is there: the two share the slot, or the display.
    private func completeSplit(_ onScreen: [(info: WindowInfo, element: AXUIElement)], managed: ManagedSpaces,
                               displays: [Displays.Connected]) {
        guard let pending = pendingSplit else { return }
        guard Date().timeIntervalSince(pending.asked) < 5 else {
            pendingSplit = nil
            Log.engine.notice("split: no second window came")
            return
        }
        guard let first = onScreen.first(where: { $0.info.id == pending.first }),
              let second = onScreen.first(where: { $0.info.pid == pending.pid && !pending.known.contains($0.info.id) && $0.info.isManageable }),
              let space = Spaces.spaceIndex(ofWindow: pending.first, managed: managed, displays: displays),
              let display = displays.first(where: { $0.identity == space.display }) else { return }
        pendingSplit = nil
        if let placement = placements[pending.first], placement.space == space, let layout = configuredSpec(space)?.layout,
           let whole = slotFrames(layout: layout, focus: focus.slot(space), visible: display.visibleAX, gap: Self.gap)[placement.slotID] {
            splits[pending.first] = SplitSide(half: .left, slotID: placement.slotID, partner: second.info.id)
            splits[second.info.id] = SplitSide(half: .right, slotID: placement.slotID, partner: pending.first)
            splitPids[pending.first] = pending.pid
            splitPids[second.info.id] = pending.pid
            rememberSplits()
            // The new window goes to the same slot, whatever its title says yet.
            chosenSlot[second.info.id] = placement.slotID
            // The first is set here: the pass leaves a window that already holds an unlocked slot.
            setFrame(pending.first, first.element, halfFrame(whole, .left, gap: Self.gap))
            Log.engine.info("split: windows \(pending.first) and \(second.info.id) share \(placement.slotID, privacy: .public)")
        } else {
            // No slot: the two halves of the display, once. The windows are the owner's after that.
            let whole = display.visibleAX.insetBy(dx: Self.gap, dy: Self.gap)
            setFrame(pending.first, first.element, halfFrame(whole, .left, gap: Self.gap))
            setFrame(second.info.id, second.element, halfFrame(whole, .right, gap: Self.gap))
            Log.engine.info("split: windows \(pending.first) and \(second.info.id) share the display")
        }
    }

    /// The two windows are no longer side by side. Returns their desktop, when one of them had a slot.
    @discardableResult
    private func endSplit(_ id: UInt32) -> SpaceKey? {
        guard let side = splits.removeValue(forKey: id) else { return nil }
        splits[side.partner] = nil
        splitPids[id] = nil
        splitPids[side.partner] = nil
        rememberSplits()
        return placements[side.partner]?.space ?? placements[id]?.space
    }

    /// A sent window outside any slot, now on its desktop: its remembered frame, or centred when it
    /// came from another display (it lands mostly off screen). Returns the frame set, if any.
    private func placeArrival(_ id: UInt32, _ element: AXUIElement, space: SpaceKey, frame: CGRect) -> CGRect? {
        guard let arrival = router.pendingArrival[id], configuredDesktop(space) == arrival.desktop else { return nil }
        router.arrived(id)
        guard arrival.frame != nil || arrival.crossDisplay,
              let display = Displays.connected().first(where: { $0.identity == space.display }) else { return nil }
        let target = arrival.frame ?? centred(frame.size, in: display.visibleAX)
        guard setFrame(id, element, target) else { return nil }
        Log.engine.info("window \(id) arrived on \(display.identity.name, privacy: .public): frame \(Int(target.minX)), \(Int(target.minY))")
        return target
    }

    private func centred(_ size: CGSize, in visible: CGRect) -> CGRect {
        let width = min(size.width, visible.width), height = min(size.height, visible.height)
        return CGRect(x: (visible.midX - width / 2).rounded(), y: (visible.midY - height / 2).rounded(), width: width, height: height)
    }

    /// Reads the window back a moment after placing it (some apps, Electron ones, resize
    /// asynchronously or drop a resize that follows the user's own). A window that kept a larger
    /// size has a minimum size larger than its slot: it is left unlocked, to avoid a fight. One that
    /// is smaller or elsewhere gets its frame again, a bounded number of times.
    private func checkFit(_ info: WindowInfo, _ element: AXUIElement, _ frame: CGRect, slotID: String,
                          retries: Int = Engine.fitRetries) {
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fitCheckDelay) { [weak self] in
            guard let self, !self.paused, self.isRunning, self.placements[info.id]?.frame == frame,
                  NSEvent.pressedMouseButtons & 1 == 0,
                  let actual = self.windows.frame(element) else { return }
            switch fitAction(fitVerdict(actual: actual, slot: frame, tolerance: self.lockGuard.tolerance), retriesLeft: retries) {
            case .keepLock:
                self.cannotFit.remove(info.id)
            case .unlock:
                self.minimumSizes.record(bundleID: info.bundleID, requested: frame.size, actual: actual.size,
                                         tolerance: self.lockGuard.tolerance)
                if self.cannotFit.insert(info.id).inserted {
                    Log.engine.notice("window \(info.id) \(info.bundleID, privacy: .public) does not take \(Int(frame.width))x\(Int(frame.height)) in \(slotID, privacy: .public), settled at \(Int(actual.width))x\(Int(actual.height)); not locked")
                }
            case .resizeAgain:
                Log.engine.info("window \(info.id) \(info.bundleID, privacy: .public) is \(Int(actual.width))x\(Int(actual.height)) after placement; setting its frame again")
                self.setFrame(info.id, element, frame)
                self.checkFit(info, element, frame, slotID: slotID, retries: retries - 1)
            }
        }
    }

    /// False when Accessibility could not set the frame (app busy, window gone): then nothing is
    /// learned from the window's size (no false minimum size) and the next pass tries again.
    @discardableResult
    private func setFrame(_ id: UInt32, _ element: AXUIElement, _ frame: CGRect) -> Bool {
        ownMoves[id] = Date()
        let result = windows.setFrame(element, frame)
        if result != .success {
            Log.engine.error("window \(id): setting its frame failed (AXError \(result.rawValue))")
        }
        return result == .success
    }

    // MARK: - Remembered placements

    /// The configured desktop a real desktop is, if any.
    func configuredDesktop(_ space: SpaceKey) -> ConfiguredDesktop? {
        guard let configuration, displaySpec(for: space.display, in: configuration) != nil,
              let index = desktopMap.configured(space.display, real: space.spaceIndex) else { return nil }
        return ConfiguredDesktop(display: space.display, index: index)
    }

    /// Records where a window is (desktop, slot, frame) when that changed or its title did (a
    /// browser's tabs may have changed), a moment later and off the placement pass.
    private func remember(_ element: AXUIElement, _ info: WindowInfo, space: SpaceKey, slotID: String?, frame: CGRect) {
        guard let configuration, let desktop = configuredDesktop(space),
              state.remembered.mayRecord(bundleID: info.bundleID, configurationID: configuration.id,
                                         recognised: router.isRecognised(info.id)) else { return }
        let known = state.remembered.entry(forWindow: info.id, configurationID: configuration.id, idsSince: router.bootTime)
        let same = known?.configurationID == configuration.id && known?.desktop == desktop && known?.slotID == slotID
            && known?.frame == frame && identities[info.id]?.title == info.title
        guard !same else { return }
        pendingRecords[info.id] = PendingRecord(element: element, info: info, desktop: desktop, slotID: slotID, frame: frame)
        guard !recordScheduled else { return }
        recordScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordDelay) { [weak self] in self?.recordPending() }
    }

    private func recordPending() {
        recordScheduled = false
        guard let configuration else { return pendingRecords.removeAll() }
        let pending = pendingRecords
        pendingRecords.removeAll()
        let now = Date()
        for (id, record) in pending {
            let identity: WindowIdentity
            if let cached = identities[id], cached.title == record.info.title {
                identity = cached.identity
            } else {
                identity = windows.identity(of: record.element, info: record.info)
                identities[id] = (record.info.title, identity)
            }
            state.remembered.record(RememberedPlacement(identity: identity, windowID: id, configurationID: configuration.id,
                                                        desktop: record.desktop, slotID: record.slotID,
                                                        frame: record.frame, lastSeen: now),
                                    idsSince: router.bootTime)
        }
        scheduleStateSave()
    }

    /// A window outside the slots moved: once it settles (button up), its remembered frame follows.
    private func noteLooseMove(_ id: UInt32) {
        guard isRunning, !paused else { return }
        looseMoves.insert(id)
        guard !looseMovesScheduled else { return }
        looseMovesScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordDelay) { [weak self] in self?.recordLooseMoves() }
    }

    private func recordLooseMoves() {
        looseMovesScheduled = false
        guard NSEvent.pressedMouseButtons & 1 == 0 else {
            looseMovesScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.recordDelay) { [weak self] in self?.recordLooseMoves() }
            return
        }
        let ids = looseMoves
        looseMoves.removeAll()
        for id in ids where placements[id] == nil && !drawers.isMember(id) {
            guard let space = Spaces.spaceIndex(ofWindow: id), configuredSpec(space)?.layout == nil,
                  let (info, element) = windows.window(id: id), info.isManageable,
                  let frame = windows.frame(element) else { continue }
            remember(element, info, space: space, slotID: nil, frame: frame)
        }
    }

    private func scheduleStateSave() {
        guard !stateSaveScheduled else { return }
        stateSaveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.stateSaveDelay) { [weak self] in
            guard let self else { return }
            self.stateSaveScheduled = false
            self.state.remembered.prune(idsSince: self.router.bootTime)
            self.saveState()
        }
    }

    /// Saves what is pending now (quitting).
    func saveStateNow() {
        if !pendingRecords.isEmpty { recordPending() }
        let membership = drawers.membership
        state.drawerMembers = membership.members
        state.takenOutOfDrawers = membership.takenOut
        state.remembered.prune(idsSince: router.bootTime)
        saveState()
    }

    // MARK: - Lock

    private func frameChanged(_ id: UInt32) {
        guard !paused, !suspended, isRunning, !drawers.isMember(id), let placement = placements[id], placement.locked, !lockGuard.isReleased(id),
              !cannotFit.contains(id) else { return }
        if let at = ownMoves[id], Date().timeIntervalSince(at) < Self.ownMoveWindow { return }
        evaluate(id, mouseDown: NSEvent.pressedMouseButtons & 1 != 0)
    }

    /// `dragged`: the change was seen while the mouse button was down, and the button is up now.
    private func evaluate(_ id: UInt32, mouseDown: Bool, dragged: Bool = false) {
        guard var placement = placements[id], let actual = windows.frame(placement.element) else { return }
        // Released inside an open drawer: the drawer takes it (and drops its placement).
        if !mouseDown, drawers.dropTarget(for: id) != nil { return }
        guard mayEnforce(running: isRunning, windowSpace: Spaces.spaceIndex(ofWindow: id), placedSpace: placement.space) else {
            // Taken to another desktop or display, into native full screen, or its display is gone:
            // the user wins. The layout of wherever it is now takes it, if any.
            Log.engine.info("window \(id) \(placement.info.bundleID, privacy: .public) left \(placement.slotID, privacy: .public); no longer enforced")
            forget(id)
            scheduleApply()
            return
        }
        if mouseDown {
            // The user is still dragging: decide once the button is up.
            if !isClose(actual, placement.frame) {
                waitingForMouseUp.insert(id)
                startMouseTimer()
            }
            return
        }
        // A window that changed its own frame is only put back (see `handChange`).
        let hand = handChange(dragged: dragged,
                              moved: isMove(actual: actual, slot: placement.frame, tolerance: lockGuard.tolerance),
                              resizeLayouts: config?.resizeLayouts == true)
        // Dropped nearer another slot that also takes this window: the user moved it there.
        if !isClose(actual, placement.frame), hand.mayDropIntoSlot,
           let moved = slotDroppedInto(placement, actual: actual) {
            memory[placement.space, default: [:]][WindowKey(placement.info)] = moved.slotID
            chosenSlot[id] = moved.slotID
            placement.slotID = moved.slotID
            placement.frame = moved.frame
            placements[id] = placement
            setFrame(id, placement.element, moved.frame)
            return
        }
        // Resized by an edge it shares with other slots, with the general setting on: the layout follows.
        if hand.mayResizeLayout, !isClose(actual, placement.frame), resizeLayout(placement, to: actual) { return }
        switch lockGuard.frameChanged(id: id, actual: actual, expected: placement.frame, mouseDown: false, now: Date()) {
        case .none:
            break
        case .restore(let frame):
            Log.engine.info("window \(id) \(placement.info.bundleID, privacy: .public) moved by hand; restored to \(placement.slotID, privacy: .public)")
            if setFrame(id, placement.element, frame) {
                checkFit(placement.info, placement.element, frame, slotID: placement.slotID)
            }
        case .release:
            Log.engine.notice("window \(id) \(placement.info.bundleID, privacy: .public) keeps fighting its slot; released until re-apply")
            placements[id] = nil
        }
    }

    /// The owner resized a slot's window by an edge it shares with other slots: that edge moves in
    /// the configuration, to the nearest clean fraction, and every slot along it follows. Saved at
    /// once. False when there is nothing to move (the edge of the screen, too small a change, a slot
    /// in Focus): the lock then decides, as before.
    private func resizeLayout(_ placement: Placement, to actual: CGRect) -> Bool {
        guard focus.slot(placement.space) == nil, let desktop = configuredDesktop(placement.space),
              let layout = configuredSpec(placement.space)?.layout,
              let display = Displays.connected().first(where: { $0.identity == placement.space.display }),
              let changed = resized(layout, slot: placement.slotID, from: placement.frame, to: actual, visible: display.visibleAX),
              isValid(changed) == nil else { return false }
        Log.engine.notice("slot \(placement.slotID, privacy: .public) resized by hand: its layout follows")
        return commands.setLayout(changed, of: desktop)
    }

    /// Exchanges the place of the active window's slot with the nearest slot on that side, in the
    /// configuration: each slot keeps its apps and its options. Beeps when there is none.
    func swapWithNeighbourSlot(_ direction: Direction) {
        guard isRunning, let element = windows.focusedWindow(), let id = AXWindows.windowID(element),
              let placement = placements[id], focus.slot(placement.space) == nil,
              let desktop = configuredDesktop(placement.space), let layout = configuredSpec(placement.space)?.layout,
              let display = Displays.connected().first(where: { $0.identity == placement.space.display }) else {
            return NSSound.beep()
        }
        let frames = slotFrames(layout: layout, focus: nil, visible: display.visibleAX, gap: Self.gap)
        guard let target = neighbourSlot(from: placement.slotID, toward: direction, frames: frames) else { return NSSound.beep() }
        if commands.setLayout(swapped(layout, placement.slotID, target), of: desktop) {
            Log.engine.notice("slots \(placement.slotID, privacy: .public) and \(target, privacy: .public) swapped")
        }
    }

    /// The other matching slot of the same layout the window was dropped closest to, if any.
    private func slotDroppedInto(_ placement: Placement, actual: CGRect) -> (slotID: String, frame: CGRect)? {
        guard let layout = configuredSpec(placement.space)?.layout,
              let display = Displays.connected().first(where: { $0.identity == placement.space.display }) else {
            return nil
        }
        let frames = slotFrames(layout: layout, focus: focus.slot(placement.space), visible: display.visibleAX,
                                gap: Self.gap)
        let matching = layout.slots.filter { matches($0, placement.info) }.map(\.id)
        let candidates = frames.filter { matching.contains($0.key) }
        guard let nearest = nearestSlot(to: actual, among: candidates), nearest != placement.slotID,
              let frame = frames[nearest] else { return nil }
        return (nearest, frame)
    }

    private func startMouseTimer() {
        guard mouseTimer == nil else { return }
        mouseTimer = Timer(timeInterval: 0.1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard NSEvent.pressedMouseButtons & 1 == 0 else { return }
            timer.invalidate()
            self.mouseTimer = nil
            let pending = self.waitingForMouseUp
            self.waitingForMouseUp.removeAll()
            guard !self.paused else { return }
            for id in pending { self.evaluate(id, mouseDown: false, dragged: true) }
            if self.applyAfterMouseUp {
                self.applyAfterMouseUp = false
                self.scheduleApply()
            }
        }
        if let mouseTimer { RunLoop.main.add(mouseTimer, forMode: .common) }
    }

    private func isClose(_ a: CGRect, _ b: CGRect) -> Bool {
        let t = lockGuard.tolerance
        return abs(a.minX - b.minX) <= t && abs(a.minY - b.minY) <= t
            && abs(a.width - b.width) <= t && abs(a.height - b.height) <= t
    }
}
