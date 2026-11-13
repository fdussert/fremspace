import Foundation

/// What Fremspace learns while it runs (desktop links, and in plan 3 where windows belong), kept
/// apart from the configuration so that the configuration file is only written by the owner.
public struct FremspaceState: Codable, Equatable {
    public var desktopLinks: DesktopLinks
    public var remembered: Remembered
    /// The slots enlarged with the Focus hotkey, so that a restart of Fremspace does not shrink them
    /// (owner, 2026-11-10).
    public var focused: [FocusedSlot]
    /// Who is in which drawer, so that a window the owner sent to a drawer is still in it after a
    /// restart of Fremspace (owner, 2026-11-10).
    public var drawerMembers: [SavedDrawerMember]
    /// The windows the owner took out of a drawer: their app's drawer slot does not take them back
    /// after a restart either.
    public var takenOutOfDrawers: [SavedWindow]
    /// How often each thing was opened from the palette (by `PaletteItem.useKey`): what the owner
    /// opens most comes first.
    public var paletteUses: [String: Int]
    /// The pairs of windows side by side in a slot, so that a restart of Fremspace does not stack
    /// them again (owner, 2026-11-12).
    public var splits: [SavedSplit]
    /// Set while the Caps Lock mapping of the Hyper key is Fremspace's own (see `hyperMappingChange`).
    public var hyperMapping: HyperMapping?

    public init(desktopLinks: DesktopLinks = DesktopLinks(), remembered: Remembered = Remembered(),
                focused: [FocusedSlot] = [], drawerMembers: [SavedDrawerMember] = [],
                takenOutOfDrawers: [SavedWindow] = [], paletteUses: [String: Int] = [:], splits: [SavedSplit] = [],
                hyperMapping: HyperMapping? = nil) {
        self.desktopLinks = desktopLinks
        self.remembered = remembered
        self.focused = focused
        self.drawerMembers = drawerMembers
        self.takenOutOfDrawers = takenOutOfDrawers
        self.paletteUses = paletteUses
        self.splits = splits
        self.hyperMapping = hyperMapping
    }

    private enum CodingKeys: String, CodingKey {
        case desktopLinks, remembered, focused, drawerMembers, takenOutOfDrawers, paletteUses, splits, hyperMapping
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        desktopLinks = try c.decodeIfPresent(DesktopLinks.self, forKey: .desktopLinks) ?? DesktopLinks()
        remembered = try c.decodeIfPresent(Remembered.self, forKey: .remembered) ?? Remembered()
        focused = try c.decodeIfPresent([FocusedSlot].self, forKey: .focused) ?? []
        drawerMembers = try c.decodeIfPresent([SavedDrawerMember].self, forKey: .drawerMembers) ?? []
        takenOutOfDrawers = try c.decodeIfPresent([SavedWindow].self, forKey: .takenOutOfDrawers) ?? []
        paletteUses = try c.decodeIfPresent([String: Int].self, forKey: .paletteUses) ?? [:]
        splits = try c.decodeIfPresent([SavedSplit].self, forKey: .splits) ?? []
        hyperMapping = try c.decodeIfPresent(HyperMapping.self, forKey: .hyperMapping)
    }
}

/// Two windows side by side in a slot, as they are found again after a restart of Fremspace.
public struct SavedSplit: Codable, Equatable {
    public var left: SavedWindow
    public var right: SavedWindow
    public var slotID: String

    public init(left: SavedWindow, right: SavedWindow, slotID: String) {
        self.left = left
        self.right = right
        self.slotID = slotID
    }
}

/// The pairs to save. `pids`: the process of each window of a pair; a pair without both is left out.
public func savedSplits(_ sides: [UInt32: SplitSide], pids: [UInt32: Int32]) -> [SavedSplit] {
    sides.filter { $0.value.half == .left }.sorted { $0.key < $1.key }.compactMap { id, side in
        guard sides[side.partner]?.partner == id, let pid = pids[id], let other = pids[side.partner] else { return nil }
        return SavedSplit(left: SavedWindow(id: id, pid: pid), right: SavedWindow(id: side.partner, pid: other), slotID: side.slotID)
    }
}

/// The pairs found again: those whose two windows still exist (`alive`: the process of every
/// window alive).
public func splitSides(_ saved: [SavedSplit], alive: [UInt32: Int32]) -> [UInt32: SplitSide] {
    var sides: [UInt32: SplitSide] = [:]
    for pair in saved where pair.left.isAlive(alive) && pair.right.isAlive(alive) && pair.left.id != pair.right.id {
        sides[pair.left.id] = SplitSide(half: .left, slotID: pair.slotID, partner: pair.right.id)
        sides[pair.right.id] = SplitSide(half: .right, slotID: pair.slotID, partner: pair.left.id)
    }
    return sides
}

/// A window as it is found again after a restart of Fremspace: its id holds while the window lives,
/// and its app's process tells a reused id apart.
public struct SavedWindow: Codable, Equatable {
    public var id: UInt32
    public var pid: Int32

    public init(id: UInt32, pid: Int32) {
        self.id = id
        self.pid = pid
    }

    /// Whether the window still exists, given the process of every window alive.
    public func isAlive(_ alive: [UInt32: Int32]) -> Bool { alive[id] == pid }
}

/// A member of a drawer: the window, its display and its slot key (`"<edge>.<slot id>"`).
public struct SavedDrawerMember: Codable, Equatable {
    public var window: SavedWindow
    public var bundleID: String
    public var display: DisplayIdentity
    public var slot: String

    public init(window: SavedWindow, bundleID: String, display: DisplayIdentity, slot: String) {
        self.window = window
        self.bundleID = bundleID
        self.display = display
        self.slot = slot
    }

    /// Whether the window still exists and is still the app's: the process that owns it must be
    /// the app that was saved (`app`: the bundle id of a process, nil when it has none, saved as
    /// "?"). An id and a process number alone can be another app's window by now.
    public func isAlive(_ alive: [UInt32: Int32], app: (Int32) -> String?) -> Bool {
        window.isAlive(alive) && (app(window.pid) ?? "?") == bundleID
    }
}

/// Whether window ids saved at `savedAt` can still name the same windows. Window ids and process
/// ids start low again at each boot, and the apps opened at login get much the same ones each
/// time; a login ends every window of the session before it. What was saved before the later of
/// the two (`idsSince`) names other windows now, however well an id and a process agree. A date
/// that cannot be read changes nothing.
public func savedWindowsHold(savedAt: Date?, idsSince: Date) -> Bool {
    savedAt.map { $0 >= idsSince } ?? true
}

extension FremspaceState {
    /// The state without what names a window by its id alone: who is in which drawer, the windows
    /// taken out of one, the pairs side by side. Remembered placements carry their own date.
    public func withoutSavedWindows() -> FremspaceState {
        var state = self
        state.drawerMembers = []
        state.takenOutOfDrawers = []
        state.splits = []
        return state
    }
}

/// A slot in Focus on a configured desktop of a configuration.
public struct FocusedSlot: Codable, Equatable {
    public var configurationID: UUID
    public var desktop: ConfiguredDesktop
    public var slotID: String

    public init(configurationID: UUID, desktop: ConfiguredDesktop, slotID: String) {
        self.configurationID = configurationID
        self.desktop = desktop
        self.slotID = slotID
    }
}

/// `state.json` next to the configuration. A missing file reads as empty; a corrupt one is set
/// aside as `state.json.corrupt` (never overwritten silently) and reads as empty.
public struct StateStore {
    public let url: URL

    public init(url: URL) {
        self.url = url
    }

    public func load() -> FremspaceState {
        guard let data = try? Data(contentsOf: url) else { return FremspaceState() }
        if let state = try? JSONDecoder().decode(FremspaceState.self, from: data) { return state }
        let kept = url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".corrupt")
        try? FileManager.default.removeItem(at: kept)
        try? FileManager.default.moveItem(at: url, to: kept)
        return FremspaceState()
    }

    /// When the file was last written, nil when there is none.
    public var savedAt: Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func save(_ state: FremspaceState) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(state).write(to: url, options: .atomic)
    }
}
