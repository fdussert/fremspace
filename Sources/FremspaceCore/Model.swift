import Foundation

/// The whole configuration file.
public struct Config: Codable, Equatable {
    /// The file format version this build reads and writes.
    public static let currentVersion = 1

    public var version: Int
    public var configurations: [Configuration]
    /// General setting, whatever the configuration in use: no floating windows on desktops with a
    /// layout. A window of an app without a slot goes to a free desktop (see `route`).
    public var noFloating: Bool = false
    /// General setting: the apps (bundle ids) whose windows stay on the desktop where they are, over
    /// its layout: neither `noFloating` nor a slot of theirs on another desktop takes them away
    /// (see `route`). In the order the owner added them.
    public var floatingApps: [String] = []
    /// General setting: the shortcuts the owner changed, by command id. A command not listed keeps
    /// its default.
    public var shortcuts: [String: Shortcut] = [:]
    /// General setting: the apps (bundle ids) whose call window goes to native full screen when the
    /// call starts (see `callWindowMarker`). An app needs no slot for this.
    public var fullScreenCalls: [String] = []
    /// General setting: Caps Lock held stands for ⌃⌥⌘ (see `hyperOutcome`).
    public var hyperKey: Bool = false
    /// General setting: resizing a slot's window by an edge it shares with other slots moves that
    /// edge in the layout (see `resized`), instead of the window snapping back.
    public var resizeLayouts: Bool = false
    /// General setting: a desktop's name shows for a moment at the top of its display when the
    /// display changes desktop (see `desktopBanner`).
    public var desktopNames: Bool = true
    /// General setting: the pointer resting on the notch shows the map of desktops.
    public var notchMap: Bool = true
    /// General setting: the palette, the maps of desktops and the editor show a picture of each
    /// window. Off unless switched on: it needs the Screen Recording permission.
    public var windowPreviews: Bool = false

    public init(version: Int = Config.currentVersion, configurations: [Configuration], noFloating: Bool = false,
                floatingApps: [String] = [],
                shortcuts: [String: Shortcut] = [:], fullScreenCalls: [String] = [], hyperKey: Bool = false,
                resizeLayouts: Bool = false, desktopNames: Bool = true, notchMap: Bool = true,
                windowPreviews: Bool = false) {
        self.version = version
        self.configurations = configurations
        self.noFloating = noFloating
        self.floatingApps = floatingApps
        self.shortcuts = shortcuts
        self.fullScreenCalls = fullScreenCalls
        self.hyperKey = hyperKey
        self.resizeLayouts = resizeLayouts
        self.desktopNames = desktopNames
        self.notchMap = notchMap
        self.windowPreviews = windowPreviews
    }

    private enum CodingKeys: String, CodingKey {
        case version, configurations, noFloating, shortcuts, fullScreenCalls, hyperKey, resizeLayouts, desktopNames, notchMap
        case windowPreviews, floatingApps
    }

    /// For one day (2026-11-10) the switch was written in each configuration.
    private struct ConfigurationSwitch: Decodable {
        var noFloating: Bool?
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        configurations = try c.decode([Configuration].self, forKey: .configurations)
        if let general = try c.decodeIfPresent(Bool.self, forKey: .noFloating) {
            noFloating = general
        } else {
            noFloating = try c.decode([ConfigurationSwitch].self, forKey: .configurations).contains { $0.noFloating == true }
        }
        // A file edited by hand may name an app twice.
        var listed = Set<String>()
        floatingApps = (try c.decodeIfPresent([String].self, forKey: .floatingApps) ?? [])
            .filter { !$0.isEmpty && listed.insert($0).inserted }
        shortcuts = try c.decodeIfPresent([String: Shortcut].self, forKey: .shortcuts) ?? [:]
        hyperKey = try c.decodeIfPresent(Bool.self, forKey: .hyperKey) ?? false
        resizeLayouts = try c.decodeIfPresent(Bool.self, forKey: .resizeLayouts) ?? false
        desktopNames = try c.decodeIfPresent(Bool.self, forKey: .desktopNames) ?? true
        notchMap = try c.decodeIfPresent(Bool.self, forKey: .notchMap) ?? true
        windowPreviews = try c.decodeIfPresent(Bool.self, forKey: .windowPreviews) ?? false
        // For one day (2026-11-10) this was an option of the app's slot.
        var calls = Set(try c.decodeIfPresent([String].self, forKey: .fullScreenCalls) ?? [])
        for ci in configurations.indices {
            for di in configurations[ci].displays.indices {
                for si in configurations[ci].displays[di].spaces.indices {
                    guard var layout = configurations[ci].displays[di].spaces[si].layout else { continue }
                    for i in layout.slots.indices where layout.slots[i].fullScreenCalls {
                        calls.formUnion(layout.slots[i].rules.map(\.bundleID).filter { callWindowMarker(bundleID: $0) != nil })
                        layout.slots[i].fullScreenCalls = false
                    }
                    configurations[ci].displays[di].spaces[si].layout = layout
                }
            }
        }
        fullScreenCalls = calls.sorted()
    }

    /// The general settings are written only when used, so other files do not change.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(configurations, forKey: .configurations)
        if noFloating { try c.encode(noFloating, forKey: .noFloating) }
        if !floatingApps.isEmpty { try c.encode(floatingApps, forKey: .floatingApps) }
        if !shortcuts.isEmpty { try c.encode(shortcuts, forKey: .shortcuts) }
        if !fullScreenCalls.isEmpty { try c.encode(fullScreenCalls, forKey: .fullScreenCalls) }
        if hyperKey { try c.encode(hyperKey, forKey: .hyperKey) }
        if resizeLayouts { try c.encode(resizeLayouts, forKey: .resizeLayouts) }
        if windowPreviews { try c.encode(windowPreviews, forKey: .windowPreviews) }
        // On unless switched off.
        if !desktopNames { try c.encode(desktopNames, forKey: .desktopNames) }
        if !notchMap { try c.encode(notchMap, forKey: .notchMap) }
    }
}

/// A named setup tied to a set of connected displays (home desk, train, other office).
public struct Configuration: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    public var displays: [DisplaySpec]
    /// Sets of desktops shown together (see `Scene`).
    public var scenes: [Scene]

    public init(id: UUID, name: String, displays: [DisplaySpec], scenes: [Scene] = []) {
        self.id = id
        self.name = name
        self.displays = displays
        self.scenes = scenes
    }

    /// What a display is called here: the owner's name for it, else the name macOS gives it.
    public func displayName(_ identity: DisplayIdentity) -> String {
        displays.first { $0.identity == identity }?.displayName ?? identity.name
    }

    private enum CodingKeys: String, CodingKey { case id, name, displays, scenes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        displays = try c.decode([DisplaySpec].self, forKey: .displays)
        scenes = try c.decodeIfPresent([Scene].self, forKey: .scenes) ?? []
    }

    /// Scenes are written only when there are some, so other files do not change.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(displays, forKey: .displays)
        if !scenes.isEmpty { try c.encode(scenes, forKey: .scenes) }
    }
}

/// A display recognised by what it is, not by where it sits. Two identities are equal when vendor,
/// model and serial are: macOS renames identical monitors "(1)" / "(2)" depending on plug order.
public struct DisplayIdentity: Codable, Hashable {
    public var vendor: UInt32
    public var model: UInt32
    public var serial: UInt32
    /// Shown to the user; not part of equality.
    public var name: String

    public init(vendor: UInt32, model: UInt32, serial: UInt32, name: String) {
        self.vendor = vendor
        self.model = model
        self.serial = serial
        self.name = name
    }

    public static func == (a: DisplayIdentity, b: DisplayIdentity) -> Bool {
        a.vendor == b.vendor && a.model == b.model && a.serial == b.serial
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(vendor)
        hasher.combine(model)
        hasher.combine(serial)
    }
}

/// One display of a configuration and its Spaces, ordered as on screen.
public struct DisplaySpec: Codable, Equatable {
    public var identity: DisplayIdentity
    /// An ignored display (the Xeneon Edge) never gets any placement.
    public var ignored: Bool
    /// Desktops by position on this display (native full-screen Spaces are not counted).
    public var spaces: [SpaceSpec]
    /// Drawers of this display, at most one per edge (they open and close together). They are the
    /// same on every desktop of the display: their windows follow the desktop shown.
    public var drawers: [DrawerSpec] {
        didSet { drawers = Self.onePerEdge(drawers) }
    }
    /// The name the owner gave the display ("Left", "Laptop"). Empty: the name macOS gives it.
    public var label: String = ""

    public init(identity: DisplayIdentity, ignored: Bool = false, spaces: [SpaceSpec], drawers: [DrawerSpec] = [],
                label: String = "") {
        self.identity = identity
        self.ignored = ignored
        self.spaces = spaces
        self.drawers = Self.onePerEdge(drawers)
        self.label = label
    }

    /// What the display is called wherever Fremspace names it: the owner's name, else macOS's.
    public var displayName: String {
        let own = label.trimmingCharacters(in: .whitespaces)
        return own.isEmpty ? identity.name : own
    }

    private enum CodingKeys: String, CodingKey { case identity, ignored, spaces, drawers, label }

    /// Drawers as the files written before 2026-11-10 hold them: on each desktop.
    private struct DesktopDrawers: Decodable {
        var drawer: DrawerSpec?
        var drawers: [DrawerSpec]?
    }

    // Written by hand so that a display without `ignored` (a file edited by hand) is not ignored,
    // rather than making the whole file unreadable, and for the drawers of older files.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identity = try c.decode(DisplayIdentity.self, forKey: .identity)
        ignored = try c.decodeIfPresent(Bool.self, forKey: .ignored) ?? false
        spaces = try c.decodeIfPresent([SpaceSpec].self, forKey: .spaces) ?? []
        if let own = try c.decodeIfPresent([DrawerSpec].self, forKey: .drawers) {
            drawers = Self.onePerEdge(own)
        } else {
            // An older file: the display takes the first drawer of each edge, in desktop order.
            let perDesktop = try c.decodeIfPresent([DesktopDrawers].self, forKey: .spaces) ?? []
            drawers = Self.onePerEdge(perDesktop.flatMap { $0.drawers ?? $0.drawer.map { [$0] } ?? [] })
        }
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
    }

    /// The owner's name is written only when there is one, so other files do not change.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(identity, forKey: .identity)
        try c.encode(ignored, forKey: .ignored)
        try c.encode(spaces, forKey: .spaces)
        try c.encode(drawers, forKey: .drawers)
        if !label.isEmpty { try c.encode(label, forKey: .label) }
    }

    /// The first drawer of each edge.
    private static func onePerEdge(_ drawers: [DrawerSpec]) -> [DrawerSpec] {
        var seen: Set<DrawerEdge> = []
        return drawers.filter { seen.insert($0.edge).inserted }
    }
}

/// What Fremspace does on one Space.
public struct SpaceSpec: Codable, Equatable {
    /// A label inside Fremspace ("Code", "Web"); not the macOS name.
    public var label: String
    /// `nil` is a free Space: Fremspace does not touch it.
    public var layout: Layout?
    /// The slot the Focus hotkey toggles to full screen, if any.
    public var focusSlot: String?
    public var unmatched: UnmatchedPolicy

    public init(label: String, layout: Layout? = nil, focusSlot: String? = nil, unmatched: UnmatchedPolicy = .float) {
        self.label = label
        self.layout = layout
        self.focusSlot = focusSlot
        self.unmatched = unmatched
    }

    private enum CodingKeys: String, CodingKey {
        case label, layout, focusSlot, unmatched
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        label = try c.decode(String.self, forKey: .label)
        layout = try c.decodeIfPresent(Layout.self, forKey: .layout)
        focusSlot = try c.decodeIfPresent(String.self, forKey: .focusSlot)
        unmatched = try c.decodeIfPresent(UnmatchedPolicy.self, forKey: .unmatched) ?? .float
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label)
        try c.encodeIfPresent(layout, forKey: .layout)
        try c.encodeIfPresent(focusSlot, forKey: .focusSlot)
        try c.encode(unmatched, forKey: .unmatched)
    }
}

/// What happens to a window that matches no slot of its Space.
public enum UnmatchedPolicy: Codable, Equatable {
    case float
    case sendTo(display: DisplayIdentity, spaceIndex: Int)
    case autoArrange
}

/// A set of slots on one display.
public struct Layout: Codable, Equatable {
    public var slots: [Slot]

    public init(slots: [Slot]) {
        self.slots = slots
    }
}

/// A region of a layout and the rule saying which windows go there.
public struct Slot: Codable, Equatable, Identifiable {
    public var id: String
    public var rect: UnitRect
    /// Which windows the slot takes (any of the rules); never empty. Several apps in one slot stack.
    public var rules: [Rule]
    /// The first rule: the slot's main app (the editor edits this one).
    public var rule: Rule {
        get { rules[0] }
        set { rules[0] = newValue }
    }
    /// A locked window snaps back when moved or resized by hand.
    public var locked: Bool = true
    /// Restore launches the app when it is not running (plan 3).
    public var launchAtLogin: Bool = true
    /// The Focus hotkey can also toggle this slot to full screen when its window is frontmost
    /// (the Space's `focusSlot` is the default target).
    public var focusable: Bool = false
    /// Read from the files of 2026-11-10 only, never written: `Config` moves it to its general
    /// `fullScreenCalls` list when it reads the file.
    public var fullScreenCalls: Bool = false

    public init(id: String, rect: UnitRect, rule: Rule, locked: Bool = true, launchAtLogin: Bool = true,
                focusable: Bool = false) {
        self.id = id
        self.rect = rect
        self.rules = [rule]
        self.locked = locked
        self.launchAtLogin = launchAtLogin
        self.focusable = focusable
    }

    private enum CodingKeys: String, CodingKey {
        case id, rect, rule, rules, locked, launchAtLogin, focusable, fullScreenCalls
    }

    // Written by hand so that a file without `locked` / `launchAtLogin` / `focusable` gets the defaults.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        rect = try c.decode(UnitRect.self, forKey: .rect)
        if let several = try c.decodeIfPresent([Rule].self, forKey: .rules), !several.isEmpty {
            rules = several
        } else {
            rules = [try c.decode(Rule.self, forKey: .rule)]
        }
        locked = try c.decodeIfPresent(Bool.self, forKey: .locked) ?? true
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? true
        focusable = try c.decodeIfPresent(Bool.self, forKey: .focusable) ?? false
        fullScreenCalls = try c.decodeIfPresent(Bool.self, forKey: .fullScreenCalls) ?? false
    }

    /// One rule is written as `rule`, so files with one app per slot do not change.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(rect, forKey: .rect)
        if rules.count == 1 {
            try c.encode(rules[0], forKey: .rule)
        } else {
            try c.encode(rules, forKey: .rules)
        }
        try c.encode(locked, forKey: .locked)
        try c.encode(launchAtLogin, forKey: .launchAtLogin)
        try c.encode(focusable, forKey: .focusable)
        // Written only when on, so files that do not use it do not change.
    }
}

/// A rectangle in fractions of the display's visible frame, origin top left.
public struct UnitRect: Codable, Equatable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }
}

/// Which windows a slot takes.
public struct Rule: Codable, Equatable {
    public var bundleID: String
    /// A browser profile name (plan 3 recognises Brave profiles).
    public var profile: String?
    /// Case-insensitive substring of the window title.
    public var titleContains: String?

    public init(bundleID: String, profile: String? = nil, titleContains: String? = nil) {
        self.bundleID = bundleID
        self.profile = profile
        self.titleContains = titleContains
    }
}
