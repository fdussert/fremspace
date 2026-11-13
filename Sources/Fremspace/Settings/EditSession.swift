import AppKit
import FremspaceCore
import SwiftUI

/// What the editor shows: a configuration, one of its displays, one desktop, and a selected slot
/// (of the layout, or of a drawer when `drawer` is set).
struct Selection: Equatable {
    var configuration = 0
    var display: DisplayIdentity?
    var desktop = 0
    var slot: String?
    /// Editing the layout of this drawer instead of the desktop's layout.
    var drawer: DrawerEdge?
}

/// What the bar at the bottom of the editor says, and how serious it is.
struct Status: Equatable {
    enum Kind { case info, success, warning, error }
    var kind: Kind
    var text: String
}

/// Why the edited configuration cannot be saved, and where to look.
struct Problem {
    var text: String
    var selection: Selection
}

/// A copy of the configuration file being edited. Nothing changes on screen until `save()`, which
/// validates, writes through `ConfigStore` (atomic, previous file kept as .bak) and reloads the engine.
final class EditSession: ObservableObject {
    @Published var config: Config {
        didSet { recordUndo(from: oldValue) }
    }
    @Published var selection = Selection()
    @Published var status: Status?
    /// Whether an export holds the browser profiles and title filters. Not in the file: asked each time.
    @Published var shareWithFilters = false
    @Published var pendingImport: PendingImport?
    @Published private(set) var library: [LibraryItem] = []
    /// The page of settings shown instead of the selected configuration, if any.
    @Published var settingsPage: SettingsPage?

    /// A command's shortcut as the owner set it ("⌃⌥⌘L"), for the texts that name it.
    func shortcutLabel(_ id: String) -> String {
        guard let shortcut = ShortcutCatalog.effective(config.shortcuts)[id], shortcut.keyCode != nil else { return "no shortcut" }
        return ShortcutCatalog.label(shortcut)
    }
    /// What the Status page lists: read when the window opens or comes back, and every few seconds.
    @Published var attention: [AttentionItem] = []
    /// The shortcuts another app holds (the app delegate knows them).
    var takenShortcuts: () -> [String] = { [] }
    private var attentionTimer: Timer?
    /// What is typed in the sidebar's search field.
    @Published var search = ""
    /// Bumped by the Edit menu's Find: the sidebar's search field takes the keyboard.
    @Published var searchRequests = 0
    /// What narrows the Shortcuts page.
    @Published var shortcutFilter = ""
    /// The setting a search result pointed at: its row is marked for a moment.
    @Published private(set) var revealed: String?

    func reveal(_ id: String) {
        revealed = id
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
            if self?.revealed == id { self?.revealed = nil }
        }
    }
    /// The connected displays and their desktop counts, read when the editor opens, when it becomes
    /// the key window and when the screens change (not on every redraw).
    @Published private(set) var connected: [Displays.Connected] = []
    @Published private(set) var desktopCounts: [DisplayIdentity: Int] = [:]
    /// Set when the file exists but cannot be read: the editor then refuses to save, so the file is
    /// never overwritten by an empty or new configuration.
    let loadError: String?
    @Published private(set) var saved: Config
    /// For the desktop shown in the editor when it is on screen: the window in front in each slot,
    /// whose picture the slot shows when previews are on.
    @Published private(set) var slotWindows: [String: UInt32] = [:]
    private var ticks = 0
    let store: ConfigStore
    let engine: Engine
    let windows: AXWindows
    private var screenToken: NSObjectProtocol?

    init(store: ConfigStore, engine: Engine, windows: AXWindows) {
        self.store = store
        self.engine = engine
        self.windows = windows
        var loaded = Config(configurations: [])
        var problem: String?
        do {
            loaded = try store.load()
        } catch let failure as ConfigError {
            switch failure {
            case .newerVersion(let v): problem = "The config file is version \(v), newer than this Fremspace."
            case .corrupt(let why): problem = "The config file cannot be read: \(why)"
            case .changedOnDisk: problem = "The config file changed while it was read."
            }
        } catch {
            problem = "The config file cannot be read: \(error.localizedDescription)"
        }
        loadError = problem
        config = loaded
        saved = loaded
        refreshEnvironment()
        // Open on the configuration in use, when there is one.
        if let active = engine.activeConfigurationID, let i = loaded.configurations.firstIndex(where: { $0.id == active }) {
            selection.configuration = i
        }
        normalizeSelection()
        screenToken = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification,
                                                             object: nil, queue: .main) { [weak self] _ in
            self?.refreshEnvironment()
        }
        attentionTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.refreshAttention()
            // The pictures every time, the windows themselves one time in four.
            self.ticks += 1
            self.refreshSlotWindows(again: self.ticks % 4 == 0)
        }
    }

    deinit {
        if let screenToken { NotificationCenter.default.removeObserver(screenToken) }
        attentionTimer?.invalidate()
    }

    var isDirty: Bool { config != saved }

    /// Where the unsaved changes are: the sidebar marks those rows, the bar beside Save names them.
    var unsaved: UnsavedChanges { unsavedChanges(edited: config, saved: saved) }

    // MARK: - Window previews

    /// The slots of the desktop shown in the editor that show their window's picture: those of the
    /// configuration applied now that are as saved. A slot being changed shows what is edited.
    var picturedSlots: Set<String> {
        guard selection.drawer == nil, let configuration, isActive(configuration), let display = selection.display,
              let space = spaceSpec,
              let was = saved.configurations.first(where: { $0.id == configuration.id })?.displays.first(where: { $0.identity == display }),
              was.spaces.indices.contains(selection.desktop) else { return [] }
        return slotsAsSaved(edited: space, saved: was.spaces[selection.desktop])
    }

    /// Reads which window stands for each slot of the desktop shown in the editor, and asks for
    /// their pictures. Reading the windows of every app is not free: `again` false keeps the
    /// windows found last time and only renews their pictures.
    func refreshSlotWindows(again: Bool = true) {
        var found: [String: UInt32] = [:]
        if WindowPreviews.shared.check(), settingsPage == nil, selection.drawer == nil, let configuration, isActive(configuration),
           let display = selection.display, spaceSpec?.layout != nil {
            found = again ? engine.slotWindows(ConfiguredDesktop(display: display, index: selection.desktop)) : slotWindows
            WindowPreviews.shared.refresh(Array(found.values))
        }
        if found != slotWindows { slotWindows = found }
    }

    /// Reads the connected displays and how many desktops each has.
    func refreshEnvironment() {
        connected = Displays.connected()
        desktopCounts = Desktops.counts()
        refreshAttention()
    }

    // MARK: - Undo, redo

    private struct Snapshot {
        var config: Config
        var removedDesktops: [RemovedDesktop]
    }

    private var undoStack: [Snapshot] = []
    private var redoStack: [Snapshot] = []
    private var lastChange = Date.distantPast
    private var restoring = false
    /// `removedDesktops` as it was before the change being recorded.
    private var removedBeforeChange: [RemovedDesktop]?

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Changes that follow one another closely (a divider drag, typing a name) undo as one step.
    private static let coalesceWithin: TimeInterval = 0.8
    private static let undoLimit = 100

    private func recordUndo(from old: Config) {
        guard !restoring, old != config else { return }
        let now = Date()
        if undoStack.isEmpty || now.timeIntervalSince(lastChange) > Self.coalesceWithin {
            undoStack.append(Snapshot(config: old, removedDesktops: removedBeforeChange ?? removedDesktops))
            if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        }
        lastChange = now
        redoStack.removeAll()
    }

    /// Ends the current undo step: the next change is a step of its own, however soon it comes.
    /// Called before discrete actions (split, remove, capture); drags and typing do not call it.
    func checkpoint() {
        lastChange = .distantPast
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(Snapshot(config: config, removedDesktops: removedDesktops))
        restore(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(Snapshot(config: config, removedDesktops: removedDesktops))
        restore(next)
    }

    private func restore(_ snapshot: Snapshot) {
        restoring = true
        config = snapshot.config
        removedDesktops = snapshot.removedDesktops
        restoring = false
        lastChange = .distantPast
        status = nil
        normalizeSelection()
    }

    // MARK: - Save, revert

    /// Why the edited configuration cannot be saved, if it cannot, and where the problem is.
    var problem: Problem? {
        for (c, configuration) in config.configurations.enumerated() {
            for display in configuration.displays {
                for (d, space) in display.spaces.enumerated() {
                    var at = Selection(configuration: c, display: display.identity, desktop: d)
                    if let layout = space.layout {
                        if let why = isValid(layout) { return Problem(text: "\(configuration.name), \(space.label): \(why)", selection: at) }
                        if let empty = layout.slots.first(where: { slot in slot.rules.contains { $0.bundleID.isEmpty } }) {
                            at.slot = empty.id
                            return Problem(text: "\(configuration.name), \(space.label): choose an app for the empty slot.", selection: at)
                        }
                    }
                }
                for drawer in display.drawers {
                    if let why = isValid(drawerAsLayout(drawer)) {
                        let at = Selection(configuration: c, display: display.identity, desktop: 0, drawer: drawer.edge)
                        return Problem(text: "\(configuration.name), \(display.displayName), \(drawer.edge.rawValue) drawer: \(why)", selection: at)
                    }
                }
            }
        }
        return nil
    }

    func save() {
        if let loadError {
            status = Status(kind: .error, text: "\(loadError) Fix it with \"Open config file\", then reopen Settings. Nothing was saved.")
            return
        }
        if let problem {
            status = Status(kind: .warning, text: problem.text)
            selection = problem.selection
            return
        }
        do {
            try store.save(config, expecting: saved)
            let previewsSwitchedOn = config.windowPreviews && !saved.windowPreviews
            saved = config
            status = Status(kind: .success, text: "Saved. The layouts apply now.")
            if !removedDesktops.isEmpty {
                // The removals are now final (links and remembered windows dropped): the undo steps
                // recorded around them count desktops the old way, so they go.
                engine.desktopsRemoved(removedDesktops)
                removedDesktops = []
                undoStack = []
                redoStack = []
            }
            engine.configurationSaved()
            // The permission is asked for when the owner switches the previews on, never before.
            if previewsSwitchedOn, !WindowPreviews.allowed { WindowPreviews.request() }
            refreshAttention()
            refreshSlotWindows()
        } catch ConfigError.changedOnDisk {
            status = Status(kind: .error, text: "The config file changed outside the editor (a Window command). Revert to load it, then make your change again. Nothing was saved.")
        } catch {
            status = Status(kind: .error, text: "Could not save: \(error.localizedDescription)")
        }
    }

    /// Back to the file as it is now (it may have changed outside the editor). One step that Undo
    /// takes back: Revert sits beside Save, and a slip there used to cost every change since the
    /// last save, the only thing in the window that could not be undone.
    func revert() {
        let before = Snapshot(config: config, removedDesktops: removedDesktops)
        if let onDisk = try? store.load() { saved = onDisk }
        guard before.config != saved || !before.removedDesktops.isEmpty else {
            status = nil
            return
        }
        undoStack.append(before)
        if undoStack.count > Self.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
        restoring = true
        config = saved
        restoring = false
        removedDesktops = []
        lastChange = .distantPast
        status = Status(kind: .info, text: "Back to the saved file. Undo brings your changes back.")
        normalizeSelection()
    }

    // MARK: - Configurations

    func select(configuration index: Int) {
        guard index != selection.configuration else { return }
        selection = Selection(configuration: index)
        normalizeSelection()
    }

    func newConfigurationFromConnectedDisplays() {
        checkpoint()
        // A display the owner already named keeps its name.
        let known = config.configurations.flatMap(\.displays).filter { !$0.label.isEmpty }
        let displays = connected.map { display in
            DisplaySpec(identity: display.identity, spaces: starterDesktops(count: desktopCounts[display.identity] ?? 1),
                        label: known.first { $0.identity == display.identity }?.label ?? "")
        }
        config.configurations.append(Configuration(id: UUID(), name: uniqueName("New configuration"), displays: displays))
        selection = Selection(configuration: config.configurations.count - 1)
        normalizeSelection()
    }

    /// A copy of the selected configuration (same displays, same layouts) under a new identity.
    func duplicateConfiguration() {
        guard var copy = configuration else { return }
        checkpoint()
        copy.id = UUID()
        copy.name = uniqueName("\(copy.name) copy")
        config.configurations.append(copy)
        selection = Selection(configuration: config.configurations.count - 1)
        normalizeSelection()
    }

    /// A configuration for that display alone, made from the selected one (see `travelConfiguration`).
    func addTravelConfiguration(keeping display: DisplayIdentity) {
        guard let source = configuration,
              let travel = travelConfiguration(from: source, keeping: display, id: UUID(),
                                               name: uniqueName("\(source.name), \(source.displayName(display)) only")) else { return }
        checkpoint()
        config.configurations.append(travel)
        selection = Selection(configuration: config.configurations.count - 1)
        normalizeSelection()
    }

    // MARK: - Sharing

    /// A layout file read, waiting for the owner to say where its displays go.
    struct PendingImport {
        var layout: SharedLayout
        /// Position in the file: the display of the selected configuration it goes to.
        var mapping: [Int: DisplayIdentity]
        var file: String
    }

    /// The file the selected configuration makes, as edited, and what is in it.
    var shareExport: (layout: SharedLayout, report: ShareReport)? {
        configuration.map { sharedLayout(of: $0, withFilters: shareWithFilters) }
    }

    /// The browser profiles and title filters of the selected configuration, each once: shown to
    /// the owner beside the switch that puts them in the file.
    var shareFilters: (profiles: [String], titles: [String]) {
        guard let configuration else { return ([], []) }
        let displays = configuration.displays.filter { !$0.ignored }
        let rules = displays.flatMap(\.spaces).flatMap { $0.layout?.slots ?? [] }.flatMap(\.rules)
            + displays.flatMap(\.drawers).flatMap(\.layout.slots).flatMap(\.rules)
        return (Array(Set(rules.compactMap(\.profile))).sorted(), Array(Set(rules.compactMap(\.titleContains))).sorted())
    }

    private func shareText() -> Data? {
        guard let export = shareExport, let data = try? export.layout.data() else {
            status = Status(kind: .error, text: "The layout could not be written.")
            return nil
        }
        return data
    }

    /// Asks where to write the file, then writes it.
    func exportLayout() {
        guard let configuration, let data = shareText() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = shareFileName(configuration.name)
        panel.canCreateDirectories = true
        panel.message = "A layout file holds no display model or serial number, and none of your shortcuts."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url, options: .atomic)
            status = Status(kind: .success, text: "Exported to \(url.lastPathComponent).")
        } catch {
            status = Status(kind: .error, text: "The file could not be written: \(error.localizedDescription)")
        }
    }

    func copyLayout() {
        guard let data = shareText() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(String(decoding: data, as: UTF8.self), forType: .string)
        status = Status(kind: .success, text: "The layout is on the clipboard.")
    }

    // The library: layout files kept beside the config file, the owner's and those of others,
    // ready to be added to a configuration.

    struct LibraryItem: Identifiable, Equatable {
        var url: URL
        var layout: SharedLayout
        var id: String { url.lastPathComponent }
    }

    var libraryFolder: URL { store.url.deletingLastPathComponent().appendingPathComponent("Layouts", isDirectory: true) }

    /// Reads the library folder again. A file that is not a layout this Fremspace can read is
    /// not listed.
    func refreshLibrary() {
        let files = (try? FileManager.default.contentsOfDirectory(at: libraryFolder, includingPropertiesForKeys: [.fileSizeKey])) ?? []
        let items = files.filter { $0.lastPathComponent.hasSuffix(SharedLayout.fileSuffix) }
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .compactMap { url -> LibraryItem? in
                guard ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) <= SharedLayout.Limit.bytes,
                      let data = try? Data(contentsOf: url), let layout = try? SharedLayout.read(data) else { return nil }
                return LibraryItem(url: url, layout: layout)
            }
        if items != library { library = items }
    }

    /// Keeps the selected configuration in the library, under its name.
    func keepInLibrary() {
        guard let configuration, let data = shareText() else { return }
        do {
            try FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
            let url = libraryFolder.appendingPathComponent(shareFileName(configuration.name))
            try data.write(to: url, options: .atomic)
            refreshLibrary()
            status = Status(kind: .success, text: "\u{201C}\(configuration.name)\u{201D} is in the library.")
        } catch {
            status = Status(kind: .error, text: "The library could not be written: \(error.localizedDescription)")
        }
    }

    /// Shows the library folder in the Finder: a layout file dropped there is listed.
    func openLibraryFolder() {
        try? FileManager.default.createDirectory(at: libraryFolder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(libraryFolder)
    }

    func removeFromLibrary(_ item: LibraryItem) {
        // To the Trash, where it can be taken back.
        try? FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
        refreshLibrary()
    }

    /// Asks for a layout file and reads it.
    func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a .fremspace-layout.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        readImport(url)
    }

    /// Reads somebody else's file. Nothing is added yet: the owner chooses where its displays go.
    func readImport(_ url: URL) {
        guard let configuration else { return }
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= SharedLayout.Limit.bytes else { throw ShareError.tooBig }
            let layout = try SharedLayout.read(try Data(contentsOf: url))
            let displays = configuration.displays.filter { !$0.ignored }.map(\.identity)
            pendingImport = PendingImport(layout: layout, mapping: defaultShareMapping(layout, onto: displays), file: url.lastPathComponent)
            status = nil
        } catch let error as ShareError {
            pendingImport = nil
            switch error {
            case .notALayout: status = Status(kind: .error, text: "\(url.lastPathComponent) is not a Fremspace layout file.")
            case .newer(let version):
                status = Status(kind: .error, text: "\(url.lastPathComponent) was written by a newer Fremspace (format \(version)). Update Fremspace to load it.")
            case .tooBig: status = Status(kind: .error, text: "\(url.lastPathComponent) is too big to be a layout file.")
            case .invalid(let what): status = Status(kind: .error, text: "\(url.lastPathComponent) cannot be loaded: \(what) is not valid. Nothing was added.")
            }
        } catch {
            pendingImport = nil
            status = Status(kind: .error, text: "\(url.lastPathComponent) could not be read: \(error.localizedDescription)")
        }
    }

    /// A display of the file goes to a display here, or is left out. One display here takes one
    /// display of the file: the one that had it before is left out.
    func mapImport(_ position: Int, to identity: DisplayIdentity?) {
        guard var pending = pendingImport else { return }
        if let identity {
            for (other, taken) in pending.mapping where taken == identity && other != position { pending.mapping[other] = nil }
        }
        pending.mapping[position] = identity
        pendingImport = pending
    }

    /// The apps of the file that are not installed here, by their identifier.
    var importMissingApps: [String] {
        guard let layout = pendingImport?.layout else { return [] }
        let rules = layout.displays.flatMap(\.desktops).flatMap { $0.layout?.slots ?? [] }.flatMap(\.rules)
            + layout.displays.flatMap(\.drawers).flatMap(\.layout.slots).flatMap(\.rules)
        let apps = Set(rules.map(\.bundleID)).union(layout.scenes.flatMap(\.apps))
        return apps.filter { NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) == nil }.sorted()
    }

    var importHasFilters: Bool {
        guard let layout = pendingImport?.layout else { return false }
        let rules = layout.displays.flatMap(\.desktops).flatMap { $0.layout?.slots ?? [] }.flatMap(\.rules)
            + layout.displays.flatMap(\.drawers).flatMap(\.layout.slots).flatMap(\.rules)
        return rules.contains { $0.profile != nil || $0.titleContains != nil }
    }

    /// Adds the file read to the selected configuration, as one step to undo. Applies with Save.
    func applyImport() {
        guard let pending = pendingImport, let configuration else { return }
        let result = adding(pending.layout, to: configuration, onto: pending.mapping)
        checkpoint()
        updateConfiguration { $0 = result.configuration }
        pendingImport = nil
        let report = result.report
        var parts = ["\(report.desktops) desktops"]
        if report.drawers > 0 { parts.append("\(report.drawers) drawers") }
        if report.scenes > 0 { parts.append("\(report.scenes) scenes") }
        var text = "Added \(parts.joined(separator: ", ")) from \u{201C}\(pending.layout.name)\u{201D}. Save to apply."
        if report.drawersKept > 0 { text += " \(report.drawersKept) of its drawers are on an edge that has yours: yours stay." }
        status = Status(kind: .success, text: text)
    }

    // MARK: - Scenes

    /// A new scene of the selected configuration. `capturing`: with the desktops its displays show
    /// now (when it is the configuration in use); else empty, every display left as it is.
    func addScene(capturing: Bool) {
        guard let configuration else { return }
        var scene = CoreScene(id: UUID(), name: "Scene \(configuration.scenes.count + 1)")
        if capturing {
            for (display, real) in Spaces.current() {
                guard let desktop = engine.configuredDesktop(SpaceKey(display: display, spaceIndex: real)),
                      configuration.id == engine.activeConfigurationID,
                      configuration.displays.contains(where: { $0.identity == display && !$0.ignored }) else { continue }
                scene.set(desktop.index, on: display)
            }
        }
        checkpoint()
        updateConfiguration { $0.scenes.append(scene) }
    }

    func updateScene(_ id: UUID, _ change: (inout CoreScene) -> Void) {
        guard let index = configuration?.scenes.firstIndex(where: { $0.id == id }) else { return }
        checkpoint()
        updateConfiguration { change(&$0.scenes[index]) }
    }

    func removeScene(_ id: UUID) {
        checkpoint()
        updateConfiguration { $0.scenes.removeAll { $0.id == id } }
    }

    func deleteConfiguration(at index: Int) {
        guard config.configurations.indices.contains(index) else { return }
        checkpoint()
        config.configurations.remove(at: index)
        selection = Selection(configuration: max(0, min(index, config.configurations.count - 1)))
        normalizeSelection()
    }

    private func uniqueName(_ base: String) -> String {
        let taken = Set(config.configurations.map(\.name))
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    /// Keeps the selection pointing at things that exist.
    func normalizeSelection() {
        guard !config.configurations.isEmpty else { selection = Selection(); return }
        if !config.configurations.indices.contains(selection.configuration) { selection.configuration = 0 }
        let displays = config.configurations[selection.configuration].displays
        if selection.display == nil || !displays.contains(where: { $0.identity == selection.display }) {
            // A connected display first: that is the one the owner can see and capture.
            let usable = displays.filter { !$0.ignored }
            selection.display = (usable.first(where: { isConnected($0.identity) }) ?? usable.first ?? displays.first)?.identity
            selection.desktop = 0
            selection.slot = nil
            selection.drawer = nil
        }
        if let display = displaySpec, !display.spaces.indices.contains(selection.desktop) {
            selection.desktop = max(0, min(selection.desktop, display.spaces.count - 1))
            selection.slot = nil
            selection.drawer = nil
        }
        if let edge = selection.drawer, displaySpec?.drawers.contains(where: { $0.edge == edge }) != true {
            selection.drawer = nil
            selection.slot = nil
        }
        if let slot = selection.slot, editedLayout?.slots.contains(where: { $0.id == slot }) != true {
            selection.slot = nil
        }
    }

    // MARK: - Access to the selection

    var configuration: Configuration? {
        config.configurations.indices.contains(selection.configuration) ? config.configurations[selection.configuration] : nil
    }

    private var displayIndex: Int? {
        configuration?.displays.firstIndex { $0.identity == selection.display }
    }

    var displaySpec: DisplaySpec? {
        displayIndex.map { config.configurations[selection.configuration].displays[$0] }
    }

    var spaceSpec: SpaceSpec? {
        guard let display = displaySpec, display.spaces.indices.contains(selection.desktop) else { return nil }
        return display.spaces[selection.desktop]
    }

    /// The selected slot of the desktop's layout (nil while a drawer is edited).
    var selectedSlot: Slot? {
        guard selection.drawer == nil, let id = selection.slot else { return nil }
        return spaceSpec?.layout?.slots.first { $0.id == id }
    }

    func select(display identity: DisplayIdentity) {
        guard identity != selection.display else { return }
        selection.display = identity
        selection.desktop = 0
        selection.slot = nil
        selection.drawer = nil
    }

    func select(desktop index: Int) {
        guard index != selection.desktop else { return }
        selection.desktop = index
        selection.slot = nil
        selection.drawer = nil
    }

    func updateConfiguration(_ change: (inout Configuration) -> Void) {
        guard config.configurations.indices.contains(selection.configuration) else { return }
        change(&config.configurations[selection.configuration])
    }

    /// A desktop removed (`to` nil) or moved to position `to`.
    typealias RemovedDesktop = (configuration: UUID, display: DisplayIdentity, index: Int, to: Int?)

    /// Desktops removed or moved since the last save, in order: on save, their uuid links and
    /// remembered windows go or follow, so that no desktop inherits another's.
    private var removedDesktops: [RemovedDesktop] = []

    /// How many desktops the saved file gives `display` in the selected configuration (nil: the
    /// configuration or the display is not saved yet).
    func savedDesktopCount(on display: DisplayIdentity) -> Int? {
        guard let id = configuration?.id else { return nil }
        return saved.configurations.first { $0.id == id }?.displays.first { $0.identity == display }?.spaces.count
    }

    /// Whether desktops of `display` were moved or removed and not saved yet: until then a position
    /// in the editor is not the position macOS has, and nothing may be read from the real desktop.
    func hasUnsavedDesktopOrder(on display: DisplayIdentity) -> Bool {
        guard let id = configuration?.id else { return false }
        return removedDesktops.contains { $0.configuration == id && $0.display == display }
    }

    func addDesktop() {
        checkpoint()
        updateDisplay { $0.spaces.append(SpaceSpec(label: "Desktop \($0.spaces.count + 1)")) }
        selection.desktop = (displaySpec?.spaces.count ?? 1) - 1
        selection.slot = nil
        selection.drawer = nil
    }

    func removeDesktop(at index: Int) {
        guard let display = displaySpec, display.spaces.count > 1, display.spaces.indices.contains(index) else { return }
        checkpoint()
        // The undo step keeps the list as it was, so that undoing the removal also forgets it.
        removedBeforeChange = removedDesktops
        removedDesktops.append((config.configurations[selection.configuration].id, display.identity, index, nil))
        updateDisplay { $0.spaces.remove(at: index) }
        updateConfiguration { $0.scenes = scenes($0.scenes, afterRemovingDesktop: index, of: display.identity) }
        removedBeforeChange = nil
        if selection.desktop > index { selection.desktop -= 1 }
        normalizeSelection()
        selection.slot = nil
        selection.drawer = nil
    }

    /// Adds a free desktop at the end of a display of the configuration (for "no floating windows"):
    /// the display with the most desktops, where one more is the least in the way. Then shows it, so
    /// the owner sees the offer to add the macOS desktop.
    func addFreeDesktop(to configurationID: UUID) {
        guard let c = config.configurations.firstIndex(where: { $0.id == configurationID }),
              let d = config.configurations[c].displays.indices.filter({ !config.configurations[c].displays[$0].ignored })
                .max(by: { config.configurations[c].displays[$0].spaces.count < config.configurations[c].displays[$1].spaces.count })
        else { return }
        checkpoint()
        config.configurations[c].displays[d].spaces.append(SpaceSpec(label: "Free"))
        let display = config.configurations[c].displays[d]
        selection = Selection(configuration: c)
        selection.display = display.identity
        selection.desktop = display.spaces.count - 1
        normalizeSelection()
        settingsPage = nil
        status = Status(kind: .info, text: "Free desktop added to \(display.displayName). Save, then add the macOS desktop if this display has one too few.")
    }

    /// Moves a desktop tab to position `to`. On save the layout takes the macOS desktop at that
    /// position and the windows are carried along (`Engine.desktopsRemoved`).
    func moveDesktop(from: Int, to: Int) {
        guard let display = displaySpec, from != to,
              display.spaces.indices.contains(from), display.spaces.indices.contains(to) else { return }
        checkpoint()
        removedBeforeChange = removedDesktops
        removedDesktops.append((config.configurations[selection.configuration].id, display.identity, from, to))
        updateDisplay { $0.spaces.insert($0.spaces.remove(at: from), at: to) }
        updateConfiguration { $0.scenes = scenes($0.scenes, afterMovingDesktop: from, to: to, of: display.identity) }
        removedBeforeChange = nil
        selection.desktop = movedIndex(selection.desktop, from: from, to: to)
    }

    /// The owner's name for a display, in every configuration that lists it: it is the same screen.
    func renameDisplay(_ identity: DisplayIdentity, to name: String) {
        var next = config
        for c in next.configurations.indices {
            for d in next.configurations[c].displays.indices where next.configurations[c].displays[d].identity == identity {
                next.configurations[c].displays[d].label = name
            }
        }
        if next != config { config = next }
    }

    func updateDisplay(_ change: (inout DisplaySpec) -> Void) {
        guard let d = displayIndex else { return }
        change(&config.configurations[selection.configuration].displays[d])
    }

    func updateSpace(_ change: (inout SpaceSpec) -> Void) {
        updateDisplay { display in
            guard display.spaces.indices.contains(selection.desktop) else { return }
            change(&display.spaces[selection.desktop])
        }
    }

    // MARK: - The layout being edited

    /// A one-slot layout to start from.
    static let starterLayout = CoreLayout(slots: [Slot(id: "main", rect: UnitRect(x: 0, y: 0, w: 1, h: 1), rule: Rule(bundleID: ""))])

    func makeLayout() {
        checkpoint()
        updateSpace { if $0.layout == nil { $0.layout = Self.starterLayout } }
        selection.slot = spaceSpec?.layout?.slots.first?.id
    }

    // MARK: - Drawers (of the display)

    static func starterDrawer(_ edge: DrawerEdge) -> DrawerSpec {
        DrawerSpec(edge: edge, size: 0.375, layout: DrawerLayout(slots: [
            DrawerSlot(id: "top", rect: UnitRect(x: 0, y: 0, w: 1, h: 0.5)),
            DrawerSlot(id: "bottom", rect: UnitRect(x: 0, y: 0.5, w: 1, h: 0.5))]))
    }

    /// Adds the drawer of `edge` to the selected display and opens it for editing.
    func addDrawer(_ edge: DrawerEdge) {
        guard displaySpec?.drawers.contains(where: { $0.edge == edge }) == false else { return }
        checkpoint()
        updateDisplay { $0.drawers.append(Self.starterDrawer(edge)) }
        editDrawer(edge)
    }

    func removeDrawer(_ edge: DrawerEdge) {
        checkpoint()
        if selection.drawer == edge {
            selection.drawer = nil
            selection.slot = nil
        }
        updateDisplay { $0.drawers.removeAll { $0.edge == edge } }
    }

    func editDrawer(_ edge: DrawerEdge?) {
        selection.drawer = edge
        selection.slot = nil
    }

    /// Changes one slot of a drawer of the selected display.
    func updateDrawerSlot(_ edge: DrawerEdge, _ id: String, _ change: (inout DrawerSlot) -> Void) {
        updateDisplay { display in
            guard let d = display.drawers.firstIndex(where: { $0.edge == edge }),
                  let s = display.drawers[d].layout.slots.firstIndex(where: { $0.id == id }) else { return }
            change(&display.drawers[d].layout.slots[s])
        }
    }

    /// Moves the apps of a layout slot to the drawer of `edge` (its first slot): their windows then
    /// live in the drawer on every desktop of the display. The slot goes; its neighbours take its
    /// place, and a desktop left without a slot becomes free.
    func moveToDrawer(slot id: String, edge: DrawerEdge) {
        guard selection.drawer == nil, let layout = spaceSpec?.layout, let slot = layout.slots.first(where: { $0.id == id }),
              let target = displaySpec?.drawers.first(where: { $0.edge == edge })?.layout.slots.first else { return }
        let apps = slot.rules.filter { !$0.bundleID.isEmpty }
        guard !apps.isEmpty else { return }
        checkpoint()
        updateDisplay { display in
            guard let d = display.drawers.firstIndex(where: { $0.edge == edge }) else { return }
            let held = display.drawers[d].layout.slots.flatMap(\.rules)
            display.drawers[d].layout.slots[0].rules += apps.filter { !held.contains($0) }
        }
        updateSpace { space in
            space.layout = layout.slots.count > 1 ? FremspaceCore.remove(layout, slot: id) : nil
            if space.focusSlot == id || space.layout == nil { space.focusSlot = nil }
        }
        selection.slot = nil
        let names = apps.map { appName($0.bundleID) }.joined(separator: ", ")
        status = Status(kind: .info, text: "\(names) moved to the \(edge.rawValue) drawer, slot \"\(target.id)\". Save to apply.")
    }

    /// The layout being edited: the desktop's, or the selected drawer's (as a layout of rule-less slots).
    var editedLayout: CoreLayout? {
        if let edge = selection.drawer {
            return displaySpec?.drawers.first(where: { $0.edge == edge }).map(drawerAsLayout)
        }
        return spaceSpec?.layout
    }

    func setEditedLayout(_ layout: CoreLayout) {
        if let edge = selection.drawer {
            updateDisplay { display in
                guard let i = display.drawers.firstIndex(where: { $0.edge == edge }) else { return }
                // A slot keeps its apps; a new one (a split) starts without any.
                let apps = Dictionary(display.drawers[i].layout.slots.map { ($0.id, $0.rules) }, uniquingKeysWith: { a, _ in a })
                display.drawers[i].layout = DrawerLayout(slots: layout.slots.map {
                    DrawerSlot(id: $0.id, rect: $0.rect, rules: apps[$0.id] ?? [])
                })
            }
        } else {
            updateSpace { $0.layout = layout }
        }
    }

    /// The unit rectangle (of the display) the edited slots live in: the whole display, or a drawer zone.
    var editedContainer: UnitRect {
        guard let edge = selection.drawer, let drawer = displaySpec?.drawers.first(where: { $0.edge == edge }) else {
            return UnitRect(x: 0, y: 0, w: 1, h: 1)
        }
        return UnitRect(x: edge == .left ? 0 : 1 - drawer.size, y: 0, w: drawer.size, h: 1)
    }

    /// Whether the selected slot can be cut along `axis` (both halves stay at least the smallest stop).
    func canSplitSelected(_ axis: CoreAxis) -> Bool {
        guard let id = selection.slot, let layout = editedLayout else { return false }
        let visible = geometry(of: selection.display).visible
        let c = editedContainer
        let length = axis == .vertical ? CGFloat(c.w) * visible.width : CGFloat(c.h) * visible.height
        return canSplit(layout, slot: id, along: axis, length: length)
    }

    func split(slot id: String, along axis: CoreAxis) {
        guard let layout = editedLayout, let slot = layout.slots.first(where: { $0.id == id }) else { return }
        checkpoint()
        var n = 2
        while layout.slots.contains(where: { $0.id == "\(id)-\(n)" }) { n += 1 }
        let newID = "\(id)-\(n)"
        setEditedLayout(FremspaceCore.split(layout, slot: id, along: axis, newID: newID, rule: slot.rule))
        selection.slot = newID
    }

    func remove(slot id: String) {
        guard let layout = editedLayout else { return }
        checkpoint()
        setEditedLayout(FremspaceCore.remove(layout, slot: id))
        if selection.drawer == nil { updateSpace { if $0.focusSlot == id { $0.focusSlot = nil } } }
        if selection.slot == id { selection.slot = nil }
    }

    // MARK: - Displays

    func isConnected(_ identity: DisplayIdentity) -> Bool {
        connected.contains { $0.identity == identity }
    }

    /// Display geometry: the connected display's frames, else a 16:10 stand-in.
    func geometry(of identity: DisplayIdentity?) -> (frame: CGRect, visible: CGRect, connected: Bool) {
        if let identity, let display = connected.first(where: { $0.identity == identity }) {
            return (display.frameAX, display.visibleAX, true)
        }
        let stand = CGRect(x: 0, y: 0, width: 1512, height: 945)
        return (stand, stand, false)
    }

    /// Whether `configuration` is the one Fremspace applies now.
    func isActive(_ configuration: Configuration) -> Bool {
        engine.activeConfigurationID == configuration.id
    }
}

/// A drawer's layout seen as a layout, so the same editing operations apply. Drawer slots have no
/// rule; the placeholder rule is dropped when writing back.
/// A drawer's slots as layout slots, for the canvas and the editing operations. A slot without an app
/// carries one empty rule (a layout slot always has a rule); `drawerApps` gives the real ones back.
func drawerAsLayout(_ drawer: DrawerSpec) -> CoreLayout {
    CoreLayout(slots: drawer.layout.slots.map { slot in
        var converted = Slot(id: slot.id, rect: slot.rect, rule: Rule(bundleID: ""))
        if !slot.rules.isEmpty { converted.rules = slot.rules }
        return converted
    })
}

/// The apps of a drawer slot shown as a layout slot.
func drawerApps(_ slot: Slot) -> [Rule] {
    slot.rules.filter { !$0.bundleID.isEmpty }
}

/// The app's display name for a bundle id ("com.brave.Browser" → "Brave Browser").
func appName(_ bundleID: String) -> String {
    if bundleID.isEmpty { return "No app" }
    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
        return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
    }
    return bundleID.split(separator: ".").last.map(String.init) ?? bundleID
}

/// "3 desktops", "1 desktop".
func counted(_ n: Int, _ noun: String) -> String {
    "\(n) \(noun)\(n == 1 ? "" : "s")"
}

// SwiftUI has its own Layout, Divider and Axis.
typealias CoreLayout = FremspaceCore.Layout
typealias CoreDivider = FremspaceCore.Divider
typealias CoreAxis = FremspaceCore.Axis

extension FremspaceCore.Divider {
    /// Same line and same slots: survives re-sorting while dragging.
    var stableID: String {
        "\(axis == .vertical ? "v" : "h"):\(before.sorted().joined(separator: ","))|\(after.sorted().joined(separator: ","))"
    }
}
typealias CoreScene = FremspaceCore.Scene
