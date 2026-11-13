import AppKit
import Combine
import FremspaceCore

/// What a row of the palette does when chosen.
enum PaletteAction {
    case window(id: UInt32, pid: pid_t)
    case app(URL)
    case desktop(ConfiguredDesktop)
    case scene(CoreScene)
    case command(String)
}

struct PaletteRow: Identifiable {
    var item: PaletteItem
    var icon: NSImage?
    /// On the right: a command's shortcut, or what the row is when its icon does not say.
    var tag: String
    var action: PaletteAction
    var id: String { item.id }
}

/// A slot on the palette's map, with the app of the window in front in it.
struct PaletteSlot {
    var rect: UnitRect
    var icon: NSImage?
    /// That window, for its picture when previews are on.
    var window: UInt32?
}

/// One desktop on the palette's map: its layout, and the apps of the windows on it.
struct PaletteDesktop: Identifiable {
    var desktop: ConfiguredDesktop
    var label: String
    /// Nil for a free desktop.
    var slots: [PaletteSlot]?
    /// The apps of the windows outside the slots, the most recent first, one per app.
    var loose: [NSImage]
    /// Whether the display shows it now.
    var shown: Bool
    var windows: Int
    var id: String { "\(desktop.display.name)#\(desktop.index)" }
}

struct PaletteDisplay: Identifiable {
    var name: String
    var desktops: [PaletteDesktop]
    /// Not the name: the owner may give two displays the same one.
    var id: String { desktops.first?.id ?? name }
}

final class PaletteModel: ObservableObject {
    @Published var query = ""
    @Published var rows: [PaletteRow] = []
    @Published var selected = 0
    /// The map of desktops, shown while nothing is typed.
    @Published var map: [PaletteDisplay] = []
    /// The desktop of the map the list is narrowed to (⇥ goes through them), nil for every window.
    @Published var desktop: ConfiguredDesktop?
    /// Window previews are on: the list has a pane with the picture of the selected window.
    @Published var showsPreviews = false
    /// The arrow keys move on the map (the chosen desktop) and no longer in the list.
    @Published var inMap = false

    var onQuery: () -> Void = {}
    var onMove: (Int) -> Void = { _ in }
    var onChoose: (Int) -> Void = { _ in }
    var onDesktop: (_ forward: Bool) -> Void = { _ in }
    /// ← and →: true when the palette took the key (nothing is typed, so there is no text to move in).
    var onSide: (Int) -> Bool = { _ in false }
    var onPickDesktop: (ConfiguredDesktop) -> Void = { _ in }
    var onClose: () -> Void = {}
    /// The pointer over a desktop of the map chooses it (the map under the notch has no keyboard).
    var hoverSelects = false
    weak var field: NSTextField?

    /// Where the chosen desktop is on the map.
    var place: MapPlace? {
        guard let desktop else { return nil }
        for (row, display) in map.enumerated() {
            if let column = display.desktops.firstIndex(where: { $0.desktop == desktop }) { return MapPlace(row: row, column: column) }
        }
        return nil
    }

    private func desktop(at place: MapPlace) -> ConfiguredDesktop? {
        guard map.indices.contains(place.row), map[place.row].desktops.indices.contains(place.column) else { return nil }
        return map[place.row].desktops[place.column].desktop
    }

    /// One arrow key on the map. With no desktop chosen yet, the key chooses the one display `row`
    /// shows and goes no further. Returns where the key led: nil when the map is empty.
    @discardableResult
    func step(dx: Int, dy: Int, from row: Int) -> MapMove? {
        guard !map.isEmpty else { return nil }
        guard let place else {
            let row = map.indices.contains(row) ? row : 0
            let start = MapPlace(row: row, column: map[row].desktops.firstIndex(where: \.shown) ?? 0)
            desktop = desktop(at: start)
            return .to(start)
        }
        let move = mapMove(rows: map.map(\.desktops.count), from: place, dx: dx, dy: dy)
        if case .to(let next) = move, let there = desktop(at: next) { desktop = there }
        return move
    }
}

private final class PalettePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

/// The palette: one field that finds an open window on any desktop, an app to launch, a desktop by
/// its name or a Fremspace command. Without a query it lists the windows, the previous one selected
/// (open, Return: back to the window before), under a map of the desktops. It takes the keyboard
/// without making Fremspace the active app, so closing it leaves the owner where they were.
final class Palette: NSObject, NSWindowDelegate {
    struct Command {
        var id: String
        var title: String
        var shortcut: String
    }

    static let listWidth: CGFloat = 640
    /// The pane with the selected window's picture, when previews are on.
    static let previewWidth: CGFloat = 380
    /// The list is at least this many rows high next to the pane, so a picture has room.
    static let previewRows = 4
    static let fieldHeight: CGFloat = 56
    static let rowHeight: CGFloat = 46
    static let visibleRows = 7
    static let mapRowHeight: CGFloat = 74

    private let engine: Engine
    private let windows: AXWindows
    private let catalog = AppCatalog()
    private let model = PaletteModel()
    private var panel: PalettePanel?
    /// Every row, in the order shown without a query.
    private var all: [PaletteRow] = []
    /// The windows of the last reading, front to back.
    private var seen: [SeenWindow] = []
    /// Elements of the windows read while their desktop was shown: Accessibility only lists those,
    /// but an element keeps answering once its window is on another desktop.
    private var elements: [UInt32: (element: AXUIElement, pid: pid_t)] = [:]
    private var titles: [UInt32: String] = [:]
    private var icons: [String: NSImage] = [:]
    private var resolving: Set<pid_t> = []
    /// The commands to list, and how to run one (the app's hotkey actions).
    var commands: () -> [Command] = { [] }
    var run: (String) -> Void = { _ in }

    /// Counts the scenes asked for: what a scene does once the displays have arrived is dropped
    /// when another was asked for meanwhile.
    private var sceneRequest = 0
    /// The scene asked for whose Focus and drawers are still to come, with the displays it switched.
    private var pendingScene: (id: UUID, changes: SceneChanges)?

    private struct SeenWindow {
        var id: UInt32
        var pid: pid_t
        var bundleID: String
        var appName: String
        var space: SpaceKey?
        var title: String
        var minimized: Bool
        var onScreen: Bool
    }

    init(engine: Engine, windows: AXWindows) {
        self.engine = engine
        self.windows = windows
        super.init()
        model.onQuery = { [weak self] in self?.queryChanged() }
        model.onMove = { [weak self] step in self?.move(step) }
        model.onChoose = { [weak self] index in self?.choose(index) }
        model.onDesktop = { [weak self] forward in self?.nextDesktop(forward: forward) }
        model.onSide = { [weak self] step in self?.side(step) ?? false }
        model.onPickDesktop = { [weak self] desktop in self?.show(desktop) }
        model.onClose = { [weak self] in self?.escape() }
        catalog.onChange = { [weak self] in
            guard let self, self.isOpen else { return }
            self.rebuild(keepSelection: true)
        }
    }

    var isOpen: Bool { panel?.isVisible ?? false }

    func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        model.query = ""
        model.desktop = nil
        model.inMap = false
        model.showsPreviews = WindowPreviews.shared.check()
        catalog.refresh()
        rebuild(keepSelection: false)
        panel.makeKeyAndOrderFront(nil)
        if let field = model.field { panel.makeFirstResponder(field) }
        let kinds = Dictionary(grouping: all, by: { $0.item.kind }).mapValues(\.count)
        Log.app.info("palette: \(kinds[.window] ?? 0) windows, \(kinds[.app] ?? 0) apps, \(kinds[.desktop] ?? 0) desktops, \(kinds[.command] ?? 0) commands")
    }

    func close() {
        guard isOpen else { return }
        panel?.orderOut(nil)
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    private func makePanel() -> PalettePanel {
        let panel = PalettePanel(contentRect: NSRect(x: 0, y: 0, width: Self.listWidth, height: Self.fieldHeight),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .modalPanel
        panel.hidesOnDeactivate = false
        // No zoom in and out: the panel is there at once, and gone at once.
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.delegate = self
        panel.contentView = PaletteHost.view(model)
        return panel
    }

    // MARK: - Rows

    private func rebuild(keepSelection: Bool) {
        let chosen = keepSelection && model.selected < model.rows.count ? model.rows[model.selected].id : nil
        seen = readWindows()
        all = windowRows() + appRows() + desktopRows() + sceneRows() + commandRows()
        model.map = map()
        filter()
        if let chosen, let index = model.rows.firstIndex(where: { $0.id == chosen }) { model.selected = index }
        if model.showsPreviews {
            // Front to back: the windows at the top of the list get their picture first.
            WindowPreviews.shared.keep(Set(seen.map(\.id)))
            WindowPreviews.shared.refresh(seen.filter { !$0.minimized }.map(\.id))
        }
    }

    private func queryChanged() {
        if !model.query.isEmpty { model.desktop = nil }
        model.inMap = false
        filter()
    }

    private func filter() {
        var items = all.map(\.item)
        if model.query.isEmpty, let desktop = model.desktop, let space = engine.realSpace(desktop) {
            let there = Set(seen.filter { $0.space == space }.map { "w:\($0.id)" })
            items = items.filter { there.contains($0.id) }
        }
        let byID = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        model.rows = paletteResults(model.query, items: items, uses: engine.paletteUses).compactMap { byID[$0.id] }.map(withIcon)
        // Without a query the first window is the one in front: the one before it is what the owner
        // most likely wants back.
        model.selected = model.query.isEmpty && model.desktop == nil && model.rows.count > 1 ? 1 : 0
        resize()
    }

    private func move(_ step: Int) {
        if model.inMap { return mapKey(dx: 0, dy: step) }
        // Up from the top of the list: onto the map, when it is there.
        if step < 0, model.query.isEmpty, !model.map.isEmpty, model.selected == 0 || model.rows.isEmpty { return mapKey(dx: 0, dy: 0) }
        guard !model.rows.isEmpty else { return }
        model.selected = (model.selected + step + model.rows.count) % model.rows.count
    }

    /// ← and → without a query go onto the map, then along its row.
    private func side(_ step: Int) -> Bool {
        guard model.query.isEmpty, !model.map.isEmpty else { return false }
        mapKey(dx: model.inMap ? step : 0, dy: 0)
        return true
    }

    /// An arrow key on the map. The first one comes onto it: at the desktop chosen with ⇥, else at
    /// the one shown by the display nearest the list. The list follows the chosen desktop; down
    /// from the last row goes into it, up from the first row gives every window back.
    private func mapKey(dx: Int, dy: Int) {
        let before = model.desktop
        let entering = !model.inMap
        model.inMap = true
        let move = entering && before != nil ? nil : model.step(dx: dx, dy: dy, from: model.map.count - 1)
        if move == .below { model.inMap = false }
        if move == .above { return wholeList() }
        if model.desktop != before { filter() }
    }

    /// Off the map and its desktop: every window again.
    private func wholeList() {
        model.inMap = false
        model.desktop = nil
        filter()
    }

    /// Escape steps back: from a desktop of the map to every window, then out of the palette.
    private func escape() {
        if model.query.isEmpty, model.inMap || model.desktop != nil { return wholeList() }
        close()
    }

    /// ⇥ without a query: the list narrows to the next desktop of the map, then back to every window.
    private func nextDesktop(forward: Bool) {
        guard model.query.isEmpty else { return move(forward ? 1 : -1) }
        model.inMap = false
        let order: [ConfiguredDesktop?] = [nil] + model.map.flatMap { $0.desktops.map { Optional($0.desktop) } }
        guard order.count > 1, let index = order.firstIndex(of: model.desktop) else { return }
        model.desktop = order[(index + (forward ? 1 : -1) + order.count) % order.count]
        filter()
    }

    private func resize() {
        guard let panel else { return }
        let size = NSSize(width: Self.width(model), height: Self.height(model))
        let screen = NSScreen.main ?? NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.screens.first
        guard let visible = screen?.visibleFrame else { return }
        // The top stays where it is while the list grows and shrinks under the field.
        let top = visible.maxY - (visible.height * 0.18).rounded()
        panel.setFrame(NSRect(x: (visible.midX - size.width / 2).rounded(), y: top - size.height, width: size.width, height: size.height),
                       display: true)
    }

    static func width(_ model: PaletteModel) -> CGFloat {
        listWidth + (model.showsPreviews ? previewWidth + 1 : 0)
    }

    static func listHeight(_ model: PaletteModel) -> CGFloat {
        guard !model.rows.isEmpty else { return 0 }
        let rows = max(min(model.rows.count, visibleRows), model.showsPreviews ? previewRows : 0)
        return CGFloat(rows) * rowHeight + 12
    }

    static func mapHeight(_ model: PaletteModel) -> CGFloat {
        model.query.isEmpty && !model.map.isEmpty ? CGFloat(model.map.count) * mapRowHeight + 16 : 0
    }

    static func height(_ model: PaletteModel) -> CGFloat {
        let list = listHeight(model), map = mapHeight(model)
        let empty: CGFloat = model.rows.isEmpty && (!model.query.isEmpty || model.desktop != nil) ? 44 : 0
        return fieldHeight + map + list + empty + (map > 0 ? 1 : 0) + (list + empty > 0 ? 1 : 0)
    }

    // MARK: - Windows

    /// Every window of a regular app on any desktop, front to back for those shown. The window list
    /// gives ids and places; names come from Accessibility, which only lists the windows of the
    /// desktops shown: for the others, the element kept from when they were, or the title Fremspace
    /// last read. A window of another desktop that was never seen is read in the background and
    /// listed once it is known.
    private func readWindows() -> [SeenWindow] {
        let managed = Spaces.managed()
        let displays = Displays.connected()
        var apps: [pid_t: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular && app.processIdentifier != getpid() {
            apps[app.processIdentifier] = app
        }
        let list = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] ?? []
        var candidates: [(id: UInt32, pid: pid_t, onScreen: Bool)] = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                  let id = (window[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, apps[pid] != nil,
                  ((window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1) > 0,
                  let bounds = (window[kCGWindowBounds as String] as? NSDictionary).flatMap({ CGRect(dictionaryRepresentation: $0) }),
                  bounds.width >= 120, bounds.height >= 60 else { continue }
            candidates.append((id, pid, (window[kCGWindowIsOnscreen as String] as? Bool) ?? false))
        }
        let alive = Set(candidates.map(\.id))
        elements = elements.filter { alive.contains($0.key) }
        titles = titles.filter { alive.contains($0.key) }

        var listed: Set<UInt32> = []
        // Apps that took the whole Accessibility timeout and did not answer (a beachball). Every
        // further question to one of them costs the timeout again, here on the main thread, where
        // the hot keys and the Hyper key's filter wait: a browser with ten windows kept the
        // palette, and typing, waiting for seconds. Their windows are listed from what is known.
        var silent: Set<pid_t> = []
        for pid in Set(candidates.map(\.pid)) {
            let asked = Date()
            guard let answer = windows.windowElementsIfAnswered(pid: pid) else {
                if Date().timeIntervalSince(asked) > Double(AXWindows.messagingTimeout) * 0.8 { silent.insert(pid) }
                continue
            }
            for element in answer {
                guard let id = AXWindows.windowID(element) else { continue }
                listed.insert(id)
                elements[id] = (element, pid)
            }
        }
        if !silent.isEmpty { Log.app.notice("palette: \(silent.count) apps do not answer; their windows are listed as last known") }
        var result: [SeenWindow] = []
        var unknown: Set<pid_t> = []
        for candidate in candidates {
            guard let app = apps[candidate.pid], let bundleID = app.bundleIdentifier else { continue }
            let quiet = silent.contains(candidate.pid)
            let element = quiet ? nil : (elements[candidate.id] ?? engine.knownElement(candidate.id))?.element
            var title: String?
            var minimized = false
            if let element {
                let subrole = Self.string(element, kAXSubroleAttribute)
                // A sheet, a tooltip, a palette: not something to go to. An element that no longer
                // answers (its window is far away) keeps the benefit of the doubt.
                if let subrole, subrole != kAXStandardWindowSubrole, subrole != kAXDialogSubrole { continue }
                title = Self.string(element, kAXTitleAttribute)
                minimized = Self.bool(element, kAXMinimizedAttribute)
            } else if !quiet, candidate.onScreen || listed.contains(candidate.id) {
                continue
            }
            title = title ?? titles[candidate.id] ?? engine.knownTitle(candidate.id)
            // A window on no desktop is never listed. Tested before its title is missed: such a
            // window never gets one, and its app was read again in the background (up to 0.3 s,
            // with a line in the log) at every opening of the palette, every rest on the notch
            // and every tick of the editor.
            let space = Spaces.spaceIndex(ofWindow: candidate.id, managed: managed, displays: displays)
            if space == nil, Spaces.spaceIDs(ofWindow: candidate.id).isEmpty { continue }
            guard let title else {
                if !quiet { unknown.insert(candidate.pid) }
                continue
            }
            titles[candidate.id] = title
            result.append(SeenWindow(id: candidate.id, pid: candidate.pid, bundleID: bundleID,
                                     appName: app.localizedName ?? WindowCommands.appName(bundleID), space: space,
                                     title: title, minimized: minimized, onScreen: candidate.onScreen))
        }
        resolve(unknown)
        return result
    }

    /// Reads the windows of other desktops of these apps off the main thread (up to 0.3 s an app).
    private func resolve(_ pids: Set<pid_t>) {
        let pending = pids.subtracting(resolving)
        guard !pending.isEmpty else { return }
        resolving.formUnion(pending)
        let windows = self.windows
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var found: [(id: UInt32, pid: pid_t, element: AXUIElement, title: String)] = []
            for pid in pending {
                for element in windows.allWindows(pid: pid) {
                    guard let id = AXWindows.windowID(element) else { continue }
                    found.append((id, pid, element, Self.string(element, kAXTitleAttribute) ?? ""))
                }
            }
            DispatchQueue.main.async {
                guard let self else { return }
                self.resolving.subtract(pending)
                var news = false
                for window in found where self.elements[window.id] == nil {
                    self.elements[window.id] = (window.element, window.pid)
                    self.titles[window.id] = window.title
                    news = true
                }
                if news, self.isOpen { self.rebuild(keepSelection: true) }
            }
        }
    }

    private static func string(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private static func bool(_ element: AXUIElement, _ attribute: String) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return false }
        return (value as? Bool) ?? false
    }

    /// Where a window is, in the owner's words.
    private func place(_ window: SeenWindow, severalDisplays: Bool) -> String {
        if engine.drawers.isMember(window.id) { return "in a drawer" }
        guard let space = window.space else { return "full screen" }
        if let label = engine.desktopSpec(space)?.label, !label.isEmpty { return label }
        return "Desktop \(space.spaceIndex + 1)" + (severalDisplays ? " of \(engine.displayName(space.display))" : "")
    }

    private func windowRows() -> [PaletteRow] {
        let severalDisplays = Displays.connected().count > 1
        return seen.map { window in
            var subtitle = "\(window.appName) · \(place(window, severalDisplays: severalDisplays))"
            if window.minimized { subtitle += " · minimised" }
            let item = PaletteItem(id: "w:\(window.id)", kind: .window, title: window.title.isEmpty ? window.appName : window.title,
                                   subtitle: subtitle, keywords: [window.appName], useKey: "wa:\(window.bundleID)")
            return PaletteRow(item: item, icon: nil, tag: "", action: .window(id: window.id, pid: window.pid))
        }
    }

    // MARK: - Apps, desktops, commands

    private func appRows() -> [PaletteRow] {
        var running: [String: NSRunningApplication] = [:]
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            if let bundleID = app.bundleIdentifier { running[bundleID] = app }
        }
        var rows: [PaletteRow] = []
        var listed: Set<String> = []
        for app in catalog.apps {
            let isRunning = app.bundleID.map { running[$0] != nil } ?? false
            if let bundleID = app.bundleID { listed.insert(bundleID) }
            let item = PaletteItem(id: "a:\(app.bundleID ?? app.url.path)", kind: .app, title: app.name,
                                   keywords: app.fileName == app.name ? [] : [app.fileName])
            rows.append(PaletteRow(item: item, icon: nil, tag: isRunning ? "Running" : "", action: .app(app.url)))
        }
        // An app run from somewhere else (a build folder).
        for (bundleID, app) in running where !listed.contains(bundleID) && app.processIdentifier != getpid() {
            guard let url = app.bundleURL else { continue }
            let item = PaletteItem(id: "a:\(bundleID)", kind: .app, title: app.localizedName ?? url.deletingPathExtension().lastPathComponent)
            rows.append(PaletteRow(item: item, icon: nil, tag: "Running", action: .app(url)))
        }
        return rows
    }

    private func desktopRows() -> [PaletteRow] {
        guard let configuration = engine.activeConfiguration else { return [] }
        let available = engine.availableDesktops
        var rows: [PaletteRow] = []
        for display in configuration.displays where !display.ignored {
            for (index, spec) in display.spaces.enumerated() {
                let desktop = ConfiguredDesktop(display: display.identity, index: index)
                guard available.contains(desktop) else { continue }
                let item = PaletteItem(id: "d:\(display.identity.name)#\(index)", kind: .desktop,
                                       title: spec.label.isEmpty ? "Desktop \(index + 1)" : spec.label,
                                       subtitle: "Desktop \(index + 1) of \(display.displayName)")
                let glyph: MenuGlyph = spec.layout.map { .layout(slots: $0.slots.map(\.rect), active: nil) } ?? .free
                rows.append(PaletteRow(item: item, icon: MenuBarIcon.image(glyph), tag: "", action: .desktop(desktop)))
            }
        }
        return rows
    }

    private func sceneRows() -> [PaletteRow] {
        guard let configuration = engine.activeConfiguration else { return [] }
        let symbol = NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: nil)
        return engine.scenes.map { scene in
            let parts = scene.desktops.compactMap { desktop -> String? in
                guard let display = displaySpec(for: desktop.display, in: configuration),
                      display.spaces.indices.contains(desktop.index) else { return nil }
                return "\(display.spaces[desktop.index].label) on \(display.displayName)"
            }
            let item = PaletteItem(id: "s:\(scene.id.uuidString)", kind: .desktop, title: scene.name,
                                   subtitle: "Scene · " + (parts.isEmpty ? "nothing to show" : parts.joined(separator: ", ")))
            return PaletteRow(item: item, icon: symbol, tag: engine.sceneInEffectID == scene.id ? "On" : "", action: .scene(scene))
        }
    }

    private func commandRows() -> [PaletteRow] {
        let symbol = NSImage(systemSymbolName: "command", accessibilityDescription: nil)
        return commands().map { command in
            PaletteRow(item: PaletteItem(id: "c:\(command.id)", kind: .command, title: command.title),
                       icon: symbol, tag: command.shortcut, action: .command(command.id))
        }
    }

    private func withIcon(_ row: PaletteRow) -> PaletteRow {
        guard row.icon == nil else { return row }
        var row = row
        switch row.action {
        case .window(_, let pid): row.icon = icon(key: "pid:\(pid)") { NSRunningApplication(processIdentifier: pid)?.icon }
        case .app(let url): row.icon = icon(key: url.path) { NSWorkspace.shared.icon(forFile: url.path) }
        case .desktop, .scene, .command: break
        }
        return row
    }

    private func icon(key: String, _ make: () -> NSImage?) -> NSImage? {
        if let known = icons[key] { return known }
        let image = make()
        icons[key] = image
        return image
    }

    // MARK: - The map

    /// The map as it is now, for the notch: the windows are read again.
    func currentMap() -> [PaletteDisplay] {
        seen = readWindows()
        let map = map()
        if WindowPreviews.shared.check() {
            WindowPreviews.shared.refresh(map.flatMap { $0.desktops.flatMap { $0.slots ?? [] }.compactMap(\.window) })
        }
        return map
    }

    private func map() -> [PaletteDisplay] {
        guard let configuration = engine.activeConfiguration else { return [] }
        let available = engine.availableDesktops
        let current = Spaces.current()
        var result: [PaletteDisplay] = []
        for display in configuration.displays where !display.ignored {
            var desktops: [PaletteDesktop] = []
            for (index, spec) in display.spaces.enumerated() {
                let desktop = ConfiguredDesktop(display: display.identity, index: index)
                guard available.contains(desktop), let space = engine.realSpace(desktop) else { continue }
                let there = seen.filter { $0.space == space && !engine.drawers.isMember($0.id) }
                func appIcon(_ window: SeenWindow) -> NSImage? {
                    icon(key: "pid:\(window.pid)") { NSRunningApplication(processIdentifier: window.pid)?.icon }
                }
                let placed = spec.layout.map { fronts(of: $0, on: desktop, among: there) }
                let slotOf = placed?.slotOf ?? [:]
                var slots: [PaletteSlot]?
                if let layout = spec.layout {
                    // A slot in Focus is drawn alone, as it is on screen.
                    let focused = engine.focusedSlot(space)
                    slots = layout.slots.filter { focused == nil || $0.id == focused }.map { slot in
                        let front = placed?.front[slot.id]
                        return PaletteSlot(rect: focused == nil ? slot.rect : UnitRect(x: 0, y: 0, w: 1, h: 1),
                                           icon: front.flatMap(appIcon), window: front.flatMap { $0.minimized ? nil : $0.id })
                    }
                }
                var apps: Set<String> = []
                let loose = there.filter { slotOf[$0.id] == nil && apps.insert($0.bundleID).inserted }.prefix(4).compactMap(appIcon)
                desktops.append(PaletteDesktop(desktop: desktop, label: spec.label.isEmpty ? "Desktop \(index + 1)" : spec.label,
                                               slots: slots, loose: Array(loose), shown: current[display.identity] == space.spaceIndex,
                                               windows: there.count))
            }
            if !desktops.isEmpty { result.append(PaletteDisplay(name: display.displayName, desktops: desktops)) }
        }
        // One desktop in all: nothing to choose between.
        return result.reduce(0) { $0 + $1.desktops.count } > 1 ? result : []
    }

    /// Which slot each window of a desktop is in (also on a desktop not shown since Fremspace
    /// started), and the window that stands for each slot. `there`: the desktop's windows, front
    /// to back.
    private func fronts(of layout: Layout, on desktop: ConfiguredDesktop, among there: [SeenWindow])
        -> (slotOf: [UInt32: String], front: [String: SeenWindow]) {
        var slotOf: [UInt32: String] = [:]
        for window in there {
            slotOf[window.id] = engine.likelySlot(of: window.id, bundleID: window.bundleID, on: desktop, layout: layout)
        }
        var front: [String: SeenWindow] = [:]
        for slot in layout.slots {
            let inSlot = there.filter { slotOf[$0.id] == slot.id }
            let chosen = slotFront(inSlot.map { SlotWindow(id: $0.id, onScreen: $0.onScreen, minimized: $0.minimized) })
            front[slot.id] = inSlot.first { $0.id == chosen?.id }
        }
        return (slotOf, front)
    }

    /// The layout of a desktop of the configuration in use, nil for a free desktop.
    private func layout(of desktop: ConfiguredDesktop) -> Layout? {
        guard let display = engine.activeConfiguration?.displays.first(where: { $0.identity == desktop.display && !$0.ignored }),
              display.spaces.indices.contains(desktop.index) else { return nil }
        return display.spaces[desktop.index].layout
    }

    /// The window to picture in each slot of a desktop, for the editor: the windows are read
    /// again. A slot whose windows are all minimised has none.
    func slotWindows(on desktop: ConfiguredDesktop) -> [String: UInt32] {
        guard let layout = layout(of: desktop), let space = engine.realSpace(desktop) else { return [:] }
        seen = readWindows()
        let there = seen.filter { $0.space == space && !engine.drawers.isMember($0.id) }
        return fronts(of: layout, on: desktop, among: there).front.compactMapValues { $0.minimized ? nil : $0.id }
    }

    // MARK: - Choosing

    private func choose(_ index: Int) {
        // Return with the keyboard on the map: the chosen desktop.
        if model.inMap, let desktop = model.desktop { return show(desktop) }
        guard index < model.rows.count else {
            // Return on a desktop of the map with no window: the desktop itself.
            if let desktop = model.desktop { show(desktop) }
            return
        }
        let row = model.rows[index]
        engine.notePaletteUse(row.item.useKey)
        switch row.action {
        case .window(let id, let pid):
            close()
            activate(window: id, pid: pid)
        case .app(let url):
            close()
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration) { _, error in
                if let error { Log.app.error("palette: \(url.lastPathComponent, privacy: .public) did not open: \(error.localizedDescription, privacy: .public)") }
            }
        case .desktop(let desktop):
            show(desktop)
        case .scene(let scene):
            show(scene: scene)
        case .command(let id):
            close()
            // Once the panel is gone, so that the command finds the owner's window in front.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.run(id) }
        }
    }

    /// Gives the keyboard to a window, which makes macOS show its desktop. False when the window
    /// could not be found; its app comes forward instead unless `orApp` is false.
    @discardableResult
    private func activate(window id: UInt32, pid: pid_t, orApp: Bool = true) -> Bool {
        var found = elements[id] ?? engine.knownElement(id)
        if found == nil, let element = windows.allWindows(pid: pid).first(where: { AXWindows.windowID($0) == id }) {
            found = (element, pid)
            elements[id] = (element, pid)
        }
        guard let found else {
            guard orApp else { return false }
            Log.app.notice("palette: window \(id) not found; its app comes forward instead")
            if let app = NSRunningApplication(processIdentifier: pid) {
                if #available(macOS 14, *) { app.activate() } else { app.activate(options: []) }
            }
            return false
        }
        if Self.bool(found.element, kAXMinimizedAttribute) {
            AXUIElementSetAttributeValue(found.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse)
        }
        windows.focus(found.element, pid: found.pid)
        return true
    }

    // MARK: - Scenes

    /// Shows a scene: each display it names goes to its desktop, one after the other, the display
    /// that has the keyboard last so that the keyboard ends on it. Displays that already show their
    /// desktop are left alone. Then comes what the scene does beyond the desktops (Focus, drawers,
    /// apps). Asked again while it is shown, the scene is left instead, and the displays go back
    /// to the desktops they showed.
    func show(scene: CoreScene) {
        close()
        seen = readWindows()
        var shown: Set<ConfiguredDesktop> = []
        for (display, real) in Spaces.current() {
            if let desktop = engine.configuredDesktop(SpaceKey(display: display, spaceIndex: real)) { shown.insert(desktop) }
        }
        sceneRequest += 1
        let request = sceneRequest
        let available = engine.availableDesktops
        let keyboard = windows.focusedWindow().flatMap(AXWindows.windowID).flatMap { Spaces.spaceIndex(ofWindow: $0)?.display }
        if sceneAction(scene, inEffect: engine.sceneInEffectID, available: available, shown: shown) == .leave {
            // Focus and drawers first, on the scene's desktops; then each display goes back to
            // the desktop it showed before the scene.
            let back = sceneReturn(engine.leaveScene(), available: available, shown: shown, keyboardOn: keyboard)
            Log.app.notice("scene \(scene.name, privacy: .public): asked again while shown, left; \(back.count) displays go back")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.showInTurn(back[...], front: { _ in nil }, request: request) { _ in }
            }
            return
        }
        // Another scene gives back what it changed before this one takes over.
        if engine.sceneInEffectID != scene.id { engine.leaveScene() }
        engine.openApps(of: scene)
        let order = sceneOrder(scene, available: available, shown: shown, keyboardOn: keyboard)
        // Showing a desktop brings one of its windows forward: that does not close a drawer the
        // scene wants open.
        engine.keepDrawersOpen(of: scene, for: 2 * Self.switchPatience * Double(order.count) + 2)
        // Asked twice in a row, before the first time took effect: where the displays came from
        // is what they showed before the first.
        var changes = SceneChanges(switches: sceneSwitches(order, shown: shown))
        if let pending = pendingScene, pending.id == scene.id { changes = pending.changes.merging(changes) }
        pendingScene = (scene.id, changes)
        let switches = changes.switches
        Log.app.notice("scene \(scene.name, privacy: .public): \(order.count) of \(scene.desktops.count) displays to switch")
        // The window of the slot the scene puts in Focus is the one that brings its desktop: any
        // other would be left in front of it.
        showInTurn(order[...], front: { scene.focus(on: $0.display) }, request: request) { [weak self] arrived in
            if !arrived { Log.app.notice("scene \(scene.name, privacy: .public): a display did not show its desktop") }
            // Focus and drawers act on the desktop shown; the windows of a desktop that just
            // arrived are still sliding in.
            DispatchQueue.main.asyncAfter(deadline: .now() + (order.isEmpty ? 0 : 0.25)) {
                guard let self, self.sceneRequest == request else { return }
                self.pendingScene = nil
                self.engine.enter(scene, switches: switches)
            }
        }
    }

    /// How long a display is given to show a desktop before it is asked again, once.
    private static let switchPatience: TimeInterval = 1.5

    /// Shows these desktops one display at a time: the next is asked for once the one before shows
    /// its desktop, because macOS drops a switch asked for while another display is still moving,
    /// and how long a switch takes is not known (a desktop without a known window goes through a
    /// helper window, slower). A display that does not move is asked once more. `done(true)` when
    /// every display arrived; nothing when another scene was asked for meanwhile.
    private func showInTurn(_ desktops: ArraySlice<ConfiguredDesktop>, front: @escaping (ConfiguredDesktop) -> String?,
                            request: Int, arrived: Bool = true, retried: Bool = false, done: @escaping (Bool) -> Void) {
        guard sceneRequest == request else { return }
        guard let desktop = desktops.first else { return done(arrived) }
        let asked = Date()
        show(desktop, front: front(desktop))
        waitUntilShown(desktop, until: asked.addingTimeInterval(Self.switchPatience)) { [weak self] shown in
            guard let self else { return }
            if !shown, !retried {
                Log.app.notice("scene: desktop \(desktop.index + 1) of \(desktop.display.name, privacy: .public) not shown after \(Self.switchPatience, format: .fixed(precision: 1)) s, asked again")
                self.seen = self.readWindows()
                return self.showInTurn(desktops, front: front, request: request, arrived: arrived, retried: true, done: done)
            }
            // Never two switches less than 0.45 s apart, and a moment for the display to settle.
            let next = max(asked.addingTimeInterval(0.45).timeIntervalSinceNow, 0.15)
            DispatchQueue.main.asyncAfter(deadline: .now() + next) {
                self.showInTurn(desktops.dropFirst(), front: front, request: request, arrived: arrived && shown, done: done)
            }
        }
    }

    /// Calls `then(true)` as soon as the display shows the desktop, `then(false)` at `deadline`.
    private func waitUntilShown(_ desktop: ConfiguredDesktop, until deadline: Date, then: @escaping (Bool) -> Void) {
        let shown = engine.realSpace(desktop).map { Spaces.current()[$0.display] == $0.spaceIndex } ?? true
        if shown || Date() >= deadline { return then(shown) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.waitUntilShown(desktop, until: deadline, then: then)
        }
    }

    /// The scene of that name (case and accents aside). False when there is none.
    @discardableResult
    func showScene(named name: String) -> Bool {
        guard let scene = engine.scenes.first(where: { paletteFold($0.name) == paletteFold(name) }) else { return false }
        show(scene: scene)
        return true
    }

    /// The scene at that position (1 is the first), for the scene shortcuts. Beeps when there is none.
    func showScene(number: Int) {
        guard engine.scenes.indices.contains(number - 1) else { return NSSound.beep() }
        show(scene: engine.scenes[number - 1])
    }

    /// Shows the desktop with that label (case and accents aside), or "2" / "DELL…/2" by position.
    /// False when no desktop answers to it.
    @discardableResult
    func showDesktop(named name: String) -> Bool {
        guard let configuration = engine.activeConfiguration else { return false }
        let wanted = paletteFold(name)
        let available = engine.availableDesktops
        for display in configuration.displays where !display.ignored {
            for (index, spec) in display.spaces.enumerated() {
                let desktop = ConfiguredDesktop(display: display.identity, index: index)
                guard available.contains(desktop) else { continue }
                if paletteFold(spec.label) == wanted || paletteFold("\(display.identity.name)/\(index + 1)") == wanted
                    || paletteFold("\(display.displayName)/\(index + 1)") == wanted {
                    seen = readWindows()
                    show(desktop)
                    return true
                }
            }
        }
        return false
    }

    /// Shows a desktop: the keyboard goes to the window of it that was in front last, which makes
    /// macOS show its desktop. A desktop without window is shown through `DesktopJump`.
    /// `front`: a slot whose window is the one to come forward (a scene puts it in Focus); without
    /// it, the slot already in Focus on that desktop, if any.
    func show(_ desktop: ConfiguredDesktop, front slotID: String? = nil) {
        close()
        guard let space = engine.realSpace(desktop) else { return NSSound.beep() }
        let there = seen.filter { $0.space == space && !$0.minimized && !engine.drawers.isMember($0.id) }
        var wanted: SeenWindow?
        // A desktop with a slot in Focus is shown by that slot's window: any other one would come
        // in front of the window that has the whole desktop (owner, 2026-11-12: Brave over Orca).
        if let slotID = slotID ?? engine.focusedSlot(on: desktop), let layout = layout(of: desktop) {
            wanted = there.first { engine.likelySlot(of: $0.id, bundleID: $0.bundleID, on: desktop, layout: layout) == slotID }
        }
        // A window in a slot rather than one floating over the layout.
        let window = wanted ?? there.first(where: { engine.slot(of: $0.id) != nil }) ?? there.first
        // After a restart the windows of the desktops not shown since are known by the window
        // list only: `activate` looks for the window itself before the helper window is used.
        if let window, activate(window: window.id, pid: window.pid, orApp: false) { return }
        if Spaces.current()[desktop.display] != space.spaceIndex,
           let sid = Spaces.spaceID(display: desktop.display, real: space.spaceIndex),
           let display = Displays.connected().first(where: { $0.identity == desktop.display }) {
            DesktopJump.show(spaceID: sid, on: display)
        }
    }
}
