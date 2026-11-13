import Foundation

/// A scene: the desktops several displays show together ("Meeting": Teams on the laptop, the notes
/// on the big display). Showing it switches every display it names; a display it does not name
/// keeps what it shows. It belongs to a configuration, whose desktops it names by position.
public struct Scene: Codable, Equatable, Identifiable {
    public var id: UUID
    public var name: String
    /// At most one desktop per display.
    public var desktops: [ConfiguredDesktop]
    /// A slot of the desktop shown that the scene puts in Focus; at most one per display.
    public var focus: [SceneFocus]
    /// The drawers the scene opens or closes; one that is not named stays as it is.
    public var drawers: [SceneDrawer]
    /// Apps (bundle identifiers) the scene opens when they are not running.
    public var apps: [String]

    public init(id: UUID, name: String, desktops: [ConfiguredDesktop] = [], focus: [SceneFocus] = [],
                drawers: [SceneDrawer] = [], apps: [String] = []) {
        self.id = id
        self.name = name
        self.desktops = desktops
        self.focus = focus
        self.drawers = drawers
        self.apps = apps
    }

    private enum CodingKeys: String, CodingKey { case id, name, desktops, focus, drawers, apps }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        desktops = try c.decodeIfPresent([ConfiguredDesktop].self, forKey: .desktops) ?? []
        focus = try c.decodeIfPresent([SceneFocus].self, forKey: .focus) ?? []
        drawers = try c.decodeIfPresent([SceneDrawer].self, forKey: .drawers) ?? []
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? []
    }

    /// What a scene does beyond the desktops is written only when there is some, so the scenes
    /// made before it existed do not change in the file.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(desktops, forKey: .desktops)
        if !focus.isEmpty { try c.encode(focus, forKey: .focus) }
        if !drawers.isEmpty { try c.encode(drawers, forKey: .drawers) }
        if !apps.isEmpty { try c.encode(apps, forKey: .apps) }
    }

    /// The desktop the scene shows on a display, nil when it leaves the display as it is.
    public func desktop(on display: DisplayIdentity) -> Int? {
        desktops.first { $0.display == display }?.index
    }

    /// Another desktop has other slots: the Focus the scene gave on that display goes with the old one.
    public mutating func set(_ index: Int?, on display: DisplayIdentity) {
        if index != desktop(on: display) { focus.removeAll { $0.display == display } }
        desktops.removeAll { $0.display == display }
        if let index { desktops.append(ConfiguredDesktop(display: display, index: index)) }
    }

    /// The slot the scene puts in Focus on a display, nil when it leaves Focus as it is.
    public func focus(on display: DisplayIdentity) -> String? {
        focus.first { $0.display == display }?.slotID
    }

    public mutating func setFocus(_ slotID: String?, on display: DisplayIdentity) {
        focus.removeAll { $0.display == display }
        if let slotID { focus.append(SceneFocus(display: display, slotID: slotID)) }
    }

    /// Whether the scene opens (true) or closes (false) a drawer, nil when it leaves it as it is.
    public func drawer(_ edge: DrawerEdge, on display: DisplayIdentity) -> Bool? {
        drawers.first { $0.display == display && $0.edge == edge }?.open
    }

    public mutating func setDrawer(_ open: Bool?, edge: DrawerEdge, on display: DisplayIdentity) {
        drawers.removeAll { $0.display == display && $0.edge == edge }
        if let open { drawers.append(SceneDrawer(display: display, edge: edge, open: open)) }
    }
}

/// A slot a scene puts in Focus, on the desktop it shows on that display.
public struct SceneFocus: Codable, Equatable {
    public var display: DisplayIdentity
    public var slotID: String

    public init(display: DisplayIdentity, slotID: String) {
        self.display = display
        self.slotID = slotID
    }
}

/// A drawer a scene opens or closes.
public struct SceneDrawer: Codable, Equatable {
    public var display: DisplayIdentity
    public var edge: DrawerEdge
    public var open: Bool

    public init(display: DisplayIdentity, edge: DrawerEdge, open: Bool) {
        self.display = display
        self.edge = edge
        self.open = open
    }
}

/// The scenes once desktop `index` of `display` is removed: a scene that showed it leaves that
/// display as it is (and gives no Focus there), and the desktops after it are one position earlier.
public func scenes(_ scenes: [Scene], afterRemovingDesktop index: Int, of display: DisplayIdentity) -> [Scene] {
    scenes.map { scene in
        var scene = scene
        scene.desktops = scene.desktops.compactMap { desktop in
            guard desktop.display == display else { return desktop }
            if desktop.index == index { return nil }
            return ConfiguredDesktop(display: display, index: desktop.index > index ? desktop.index - 1 : desktop.index)
        }
        // Its slots went with it.
        if scene.desktop(on: display) == nil { scene.focus.removeAll { $0.display == display } }
        return scene
    }
}

/// The scenes once a desktop of `display` moved from one position to another: they keep showing the
/// same desktops.
public func scenes(_ scenes: [Scene], afterMovingDesktop from: Int, to: Int, of display: DisplayIdentity) -> [Scene] {
    scenes.map { scene in
        var scene = scene
        scene.desktops = scene.desktops.map { desktop in
            desktop.display == display
                ? ConfiguredDesktop(display: display, index: movedIndex(desktop.index, from: from, to: to)) : desktop
        }
        return scene
    }
}

/// The desktops to show for a scene, in order: only those that are there (`available`) and not
/// shown already (`shown`), the display that has the keyboard last, so that the keyboard ends on it.
public func sceneOrder(_ scene: Scene, available: Set<ConfiguredDesktop>, shown: Set<ConfiguredDesktop>,
                       keyboardOn: DisplayIdentity?) -> [ConfiguredDesktop] {
    let wanted = scene.desktops.filter { available.contains($0) && !shown.contains($0) }
    return wanted.filter { $0.display != keyboardOn } + wanted.filter { $0.display == keyboardOn }
}


// MARK: - Beyond the desktops

/// Focus on a desktop: a slot, or none.
public struct FocusSetting: Equatable {
    public var desktop: ConfiguredDesktop
    public var slotID: String?

    public init(desktop: ConfiguredDesktop, slotID: String?) {
        self.desktop = desktop
        self.slotID = slotID
    }
}

/// What a scene changed when it was shown, beyond the desktops: leaving it gives back only that.
public struct SceneChanges: Equatable {
    /// A Focus the scene gave, and the slot that had it before (nil: none).
    public struct Focus: Equatable {
        public var desktop: ConfiguredDesktop
        public var slotID: String
        public var was: String?

        public init(desktop: ConfiguredDesktop, slotID: String, was: String?) {
            self.desktop = desktop
            self.slotID = slotID
            self.was = was
        }
    }

    /// A display the scene switched: the desktop it showed before, and the scene's.
    public struct Switch: Equatable {
        public var from: ConfiguredDesktop
        public var to: ConfiguredDesktop

        public init(from: ConfiguredDesktop, to: ConfiguredDesktop) {
            self.from = from
            self.to = to
        }
    }

    public var focus: [Focus]
    /// The drawers as the scene set them; each was the other way before.
    public var drawers: [SceneDrawer]
    public var switches: [Switch]

    public init(focus: [Focus] = [], drawers: [SceneDrawer] = [], switches: [Switch] = []) {
        self.focus = focus
        self.drawers = drawers
        self.switches = switches
    }

    public var isEmpty: Bool { focus.isEmpty && drawers.isEmpty && switches.isEmpty }

    /// The same scene shown again after the owner went elsewhere: what it changes now is added,
    /// and what a desktop or a drawer was like before the scene is kept from the first time.
    public func merging(_ later: SceneChanges) -> SceneChanges {
        var merged = self
        for step in later.focus {
            if let index = merged.focus.firstIndex(where: { $0.desktop == step.desktop }) {
                merged.focus[index].slotID = step.slotID
            } else {
                merged.focus.append(step)
            }
        }
        for drawer in later.drawers where !merged.drawers.contains(where: { $0.display == drawer.display && $0.edge == drawer.edge }) {
            merged.drawers.append(drawer)
        }
        for change in later.switches where !merged.switches.contains(where: { $0.to.display == change.to.display }) {
            merged.switches.append(change)
        }
        return merged
    }
}

/// The Focus a scene gives: on each of its desktops that is there, the slot it names, when the
/// layout still has it among those Focus enlarges and it is not in Focus already.
public func sceneFocusSteps(_ scene: Scene, in configuration: Configuration, available: Set<ConfiguredDesktop>,
                            focused: (ConfiguredDesktop) -> String?) -> [SceneChanges.Focus] {
    scene.focus.compactMap { wanted in
        guard let index = scene.desktop(on: wanted.display),
              case let desktop = ConfiguredDesktop(display: wanted.display, index: index), available.contains(desktop),
              let display = configuration.displays.first(where: { $0.identity == wanted.display && !$0.ignored }),
              display.spaces.indices.contains(index),
              focusSlots(display.spaces[index]).contains(where: { $0.id == wanted.slotID }) else { return nil }
        let now = focused(desktop)
        return now == wanted.slotID ? nil : SceneChanges.Focus(desktop: desktop, slotID: wanted.slotID, was: now)
    }
}

/// Whether the configuration still has the drawer a scene names, on a display that is not ignored.
public func sceneHasDrawer(_ drawer: SceneDrawer, in configuration: Configuration) -> Bool {
    configuration.displays.contains { $0.identity == drawer.display && !$0.ignored && $0.drawers.contains { $0.edge == drawer.edge } }
}

/// The drawers a scene moves: those it names that the display still has and that are the other way.
public func sceneDrawerSteps(_ scene: Scene, in configuration: Configuration,
                             isOpen: (DisplayIdentity, DrawerEdge) -> Bool) -> [SceneDrawer] {
    scene.drawers.filter { sceneHasDrawer($0, in: configuration) && isOpen($0.display, $0.edge) != $0.open }
}

/// Leaving a scene: what it changed and that is still as it left it goes back to what it was. A
/// Focus or a drawer the owner changed since is the owner's and stays.
public func sceneUndo(_ changes: SceneChanges, focused: (ConfiguredDesktop) -> String?,
                      isOpen: (DisplayIdentity, DrawerEdge) -> Bool) -> (focus: [FocusSetting], drawers: [SceneDrawer]) {
    let focus = changes.focus.filter { focused($0.desktop) == $0.slotID }.map { FocusSetting(desktop: $0.desktop, slotID: $0.was) }
    let drawers = changes.drawers.filter { isOpen($0.display, $0.edge) == $0.open }
        .map { SceneDrawer(display: $0.display, edge: $0.edge, open: !$0.open) }
    return (focus, drawers)
}

/// The displays a scene switches, with what each shows now: the desktops to go back to on leaving.
/// A display that shows no configured desktop (a full-screen app) has nothing to go back to.
public func sceneSwitches(_ order: [ConfiguredDesktop], shown: Set<ConfiguredDesktop>) -> [SceneChanges.Switch] {
    order.compactMap { to in
        shown.first { $0.display == to.display }.map { SceneChanges.Switch(from: $0, to: to) }
    }
}

/// Leaving a scene: the desktops to show again, on the displays it switched that still show the
/// scene's desktop, when the one they came from is still there. The display that has the keyboard
/// last, so that the keyboard ends on it.
public func sceneReturn(_ changes: SceneChanges, available: Set<ConfiguredDesktop>, shown: Set<ConfiguredDesktop>,
                        keyboardOn: DisplayIdentity?) -> [ConfiguredDesktop] {
    let back = changes.switches.filter { shown.contains($0.to) && available.contains($0.from) }.map(\.from)
    return back.filter { $0.display != keyboardOn } + back.filter { $0.display == keyboardOn }
}

/// The drawers a scene opened on a display that now shows another desktop than the scene's: they
/// close. An open drawer follows its display from desktop to desktop; the scene opened it for
/// its own desktop, not for the one the owner goes to next. A display the scene does not name a
/// desktop for has no desktop to leave.
public func sceneDrawersLeftBehind(_ changes: SceneChanges, desktops: [ConfiguredDesktop],
                                   shown: Set<ConfiguredDesktop>) -> [SceneDrawer] {
    changes.drawers.filter { drawer in
        guard drawer.open, let desktop = desktops.first(where: { $0.display == drawer.display }) else { return false }
        return !shown.contains(desktop)
    }
}

/// The apps a scene opens: those it names that are not running, each once.
public func sceneAppsToOpen(_ scene: Scene, running: Set<String>) -> [String] {
    var seen = running
    return scene.apps.filter { !$0.isEmpty && seen.insert($0).inserted }
}

public enum SceneAction: Equatable {
    case enter, leave
}

/// Asking for a scene shows it; asking again while it is in effect and every display still shows
/// its desktop leaves it. After the owner went to another desktop, asking again goes back to it.
public func sceneAction(_ scene: Scene, inEffect: UUID?, available: Set<ConfiguredDesktop>,
                        shown: Set<ConfiguredDesktop>) -> SceneAction {
    guard inEffect == scene.id else { return .enter }
    return scene.desktops.allSatisfy { !available.contains($0) || shown.contains($0) } ? .leave : .enter
}
