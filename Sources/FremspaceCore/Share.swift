import Foundation

/// A configuration written for somebody else: its desktops, layouts, drawers and scenes, without
/// anything that says whose desk it is. Displays are named by position and by the owner's name for
/// them, never by model or serial number. The file is `<name>.fremspace-layout.json`.
public struct SharedLayout: Codable, Equatable {
    public static let kind = "fremspace-layout"
    public static let currentVersion = 1
    public static let fileSuffix = ".fremspace-layout.json"

    public var kind: String
    public var version: Int
    /// The Fremspace that wrote the file.
    public var app: String
    public var name: String
    public var displays: [SharedDisplay]
    public var scenes: [SharedScene]

    public init(name: String, displays: [SharedDisplay], scenes: [SharedScene] = [], app: String = FremspaceCore.version) {
        self.kind = Self.kind
        self.version = Self.currentVersion
        self.app = app
        self.name = name
        self.displays = displays
        self.scenes = scenes
    }

    /// The file's text: one value per line and the keys in order, so that two exports compare.
    public func data() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public struct SharedDisplay: Codable, Equatable {
    /// The owner's name for the display ("Main"), else "Display 2".
    public var name: String
    public var desktops: [SpaceSpec]
    public var drawers: [DrawerSpec]

    public init(name: String, desktops: [SpaceSpec], drawers: [DrawerSpec] = []) {
        self.name = name
        self.desktops = desktops
        self.drawers = drawers
    }
}

/// A scene whose displays are positions in the file's list.
public struct SharedScene: Codable, Equatable {
    public struct Desktop: Codable, Equatable {
        public var display: Int
        public var index: Int
        public init(display: Int, index: Int) {
            self.display = display
            self.index = index
        }
    }

    public struct Focus: Codable, Equatable {
        public var display: Int
        public var slotID: String
        public init(display: Int, slotID: String) {
            self.display = display
            self.slotID = slotID
        }
    }

    public struct Drawer: Codable, Equatable {
        public var display: Int
        public var edge: DrawerEdge
        public var open: Bool
        public init(display: Int, edge: DrawerEdge, open: Bool) {
            self.display = display
            self.edge = edge
            self.open = open
        }
    }

    public var name: String
    public var desktops: [Desktop]
    public var focus: [Focus]
    public var drawers: [Drawer]
    public var apps: [String]

    public init(name: String, desktops: [Desktop] = [], focus: [Focus] = [], drawers: [Drawer] = [], apps: [String] = []) {
        self.name = name
        self.desktops = desktops
        self.focus = focus
        self.drawers = drawers
        self.apps = apps
    }
}

// MARK: - Writing

/// What an export holds and what it left out, for the owner to read before the file is written.
public struct ShareReport: Equatable {
    public var displays = 0
    public var desktops = 0
    public var slots = 0
    public var drawers = 0
    public var scenes = 0
    /// The apps the layouts, the drawers and the scenes name, each once, sorted.
    public var apps: [String] = []
    /// Browser profiles and window title filters taken out of the rules.
    public var profilesLeftOut = 0
    public var titleFiltersLeftOut = 0
    /// Displays the configuration ignores: not in the file.
    public var displaysIgnored = 0

    public init() {}
}

/// The file for a configuration. Never in it: the displays' models and serial numbers (a display
/// is its position and the owner's name for it), and whatever is not the configuration (shortcuts,
/// general settings, what Fremspace remembers). A browser profile and a window title filter are
/// free text that can name an employer or a customer: they go in only `withFilters`.
public func sharedLayout(of configuration: Configuration, withFilters: Bool) -> (layout: SharedLayout, report: ShareReport) {
    var report = ShareReport()
    var apps: Set<String> = []

    func shared(_ rules: [Rule]) -> [Rule] {
        var result: [Rule] = []
        for rule in rules {
            if !withFilters {
                if rule.profile != nil { report.profilesLeftOut += 1 }
                if rule.titleContains != nil { report.titleFiltersLeftOut += 1 }
            }
            let kept = withFilters ? rule : Rule(bundleID: rule.bundleID)
            apps.insert(kept.bundleID)
            // Two rules that differed by their profile only are one rule now.
            if !result.contains(kept) { result.append(kept) }
        }
        return result
    }

    let kept = configuration.displays.filter { !$0.ignored }
    report.displaysIgnored = configuration.displays.count - kept.count
    var displays: [SharedDisplay] = []
    for (position, display) in kept.enumerated() {
        var desktops = display.spaces
        for d in desktops.indices {
            guard var layout = desktops[d].layout else { continue }
            for s in layout.slots.indices { layout.slots[s].rules = shared(layout.slots[s].rules) }
            report.slots += layout.slots.count
            desktops[d].layout = layout
        }
        var drawers = display.drawers
        for d in drawers.indices {
            for s in drawers[d].layout.slots.indices {
                drawers[d].layout.slots[s].rules = shared(drawers[d].layout.slots[s].rules)
            }
        }
        report.desktops += desktops.count
        report.drawers += drawers.count
        displays.append(SharedDisplay(name: display.label.isEmpty ? "Display \(position + 1)" : display.label,
                                      desktops: desktops, drawers: drawers))
    }
    report.displays = displays.count

    func position(_ identity: DisplayIdentity) -> Int? { kept.firstIndex { $0.identity == identity } }
    let scenes = configuration.scenes.map { scene in
        SharedScene(
            name: scene.name,
            desktops: scene.desktops.compactMap { desktop in
                position(desktop.display).map { SharedScene.Desktop(display: $0, index: desktop.index) }
            },
            focus: scene.focus.compactMap { focus in
                position(focus.display).map { SharedScene.Focus(display: $0, slotID: focus.slotID) }
            },
            drawers: scene.drawers.compactMap { drawer in
                position(drawer.display).map { SharedScene.Drawer(display: $0, edge: drawer.edge, open: drawer.open) }
            },
            apps: scene.apps)
    }
    for scene in scenes { apps.formUnion(scene.apps) }
    report.scenes = scenes.count
    report.apps = apps.filter { !$0.isEmpty }.sorted()
    return (SharedLayout(name: configuration.name, displays: displays, scenes: scenes), report)
}

/// The name of the file for a configuration: its name without what a file name cannot hold.
public func shareFileName(_ name: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: " -_"))
    let kept = String(String.UnicodeScalarView(name.unicodeScalars.filter { allowed.contains($0) }))
        .trimmingCharacters(in: .whitespaces)
    return (kept.isEmpty ? "Fremspace" : kept) + SharedLayout.fileSuffix
}

// MARK: - Reading

public enum ShareError: Error, Equatable {
    /// Not a Fremspace layout file.
    case notALayout
    /// Written by a newer Fremspace, in a format this one does not know.
    case newer(version: Int)
    case tooBig
    /// A layout file, with something in it that cannot be: what, in a few words.
    case invalid(String)
}

extension SharedLayout {
    /// The most a file may hold. It is somebody else's file: nothing in it is taken at its word.
    public enum Limit {
        public static let bytes = 1_000_000
        public static let displays = 8
        public static let desktops = 16
        public static let slots = 16
        public static let rules = 8
        public static let scenes = 32
        public static let apps = 16
        public static let text = 60
        public static let id = 40
        public static let bundleID = 200
    }

    private struct Header: Decodable {
        var kind: String?
        var version: Int?
    }

    /// Reads a file: its kind and version first, then every value against the limits. Names are
    /// cut to a line of text; an identifier, a rectangle or a position that cannot be is refused.
    public static func read(_ data: Data) throws -> SharedLayout {
        guard data.count <= Limit.bytes else { throw ShareError.tooBig }
        guard let header = try? JSONDecoder().decode(Header.self, from: data), header.kind == kind,
              let version = header.version, version >= 1 else { throw ShareError.notALayout }
        guard version <= currentVersion else { throw ShareError.newer(version: version) }
        guard var layout = try? JSONDecoder().decode(SharedLayout.self, from: data) else {
            throw ShareError.invalid("a value is missing or of the wrong kind")
        }
        layout.app = clean(layout.app, fallback: "?")
        layout.name = clean(layout.name, fallback: "Layout")
        guard (1...Limit.displays).contains(layout.displays.count) else { throw ShareError.invalid("the number of displays") }
        guard layout.scenes.count <= Limit.scenes else { throw ShareError.invalid("the number of scenes") }
        for d in layout.displays.indices {
            layout.displays[d] = try checked(layout.displays[d], position: d)
        }
        layout.scenes = layout.scenes.map { checked($0, in: layout.displays) }
        return layout
    }

    private static func checked(_ display: SharedDisplay, position: Int) throws -> SharedDisplay {
        var display = display
        display.name = clean(display.name, fallback: "Display \(position + 1)")
        guard display.desktops.count <= Limit.desktops else { throw ShareError.invalid("the number of desktops") }
        for d in display.desktops.indices {
            display.desktops[d].label = clean(display.desktops[d].label, fallback: "Desktop \(d + 1)")
            guard var layout = display.desktops[d].layout else {
                display.desktops[d].focusSlot = nil
                continue
            }
            guard layout.slots.count <= Limit.slots else { throw ShareError.invalid("the number of slots") }
            var ids: Set<String> = []
            for s in layout.slots.indices {
                let slot = layout.slots[s]
                guard isID(slot.id), ids.insert(slot.id).inserted else { throw ShareError.invalid("a slot's identifier") }
                guard isUnit(slot.rect) else { throw ShareError.invalid("a slot's rectangle") }
                guard !slot.rules.isEmpty else { throw ShareError.invalid("a slot without app") }
                layout.slots[s].rules = try checked(slot.rules)
                // The option of one day (see `Slot.fullScreenCalls`) is read and never written:
                // left on, the configuration in memory would never equal the file it was saved
                // to, and every later Save would be refused as "changed outside the editor".
                layout.slots[s].fullScreenCalls = false
            }
            display.desktops[d].layout = layout
            if let focus = display.desktops[d].focusSlot, !ids.contains(focus) { display.desktops[d].focusSlot = nil }
        }
        guard Set(display.drawers.map(\.edge)).count == display.drawers.count else { throw ShareError.invalid("two drawers on one edge") }
        for d in display.drawers.indices {
            let drawer = display.drawers[d]
            guard drawer.size.isFinite, drawer.size > 0, drawer.size < 1 else { throw ShareError.invalid("a drawer's size") }
            guard drawer.layout.slots.count <= Limit.slots else { throw ShareError.invalid("the number of drawer slots") }
            var ids: Set<String> = []
            for s in drawer.layout.slots.indices {
                let slot = drawer.layout.slots[s]
                guard isID(slot.id), ids.insert(slot.id).inserted else { throw ShareError.invalid("a drawer slot's identifier") }
                guard isUnit(slot.rect) else { throw ShareError.invalid("a drawer slot's rectangle") }
                display.drawers[d].layout.slots[s].rules = try checked(slot.rules)
            }
        }
        return display
    }

    private static func checked(_ rules: [Rule]) throws -> [Rule] {
        guard rules.count <= Limit.rules else { throw ShareError.invalid("the number of apps in a slot") }
        return try rules.map { rule in
            guard isBundleID(rule.bundleID) else { throw ShareError.invalid("an app's identifier") }
            return Rule(bundleID: rule.bundleID, profile: rule.profile.map { clean($0, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 },
                        titleContains: rule.titleContains.map { clean($0, fallback: "") }.flatMap { $0.isEmpty ? nil : $0 })
        }
    }

    /// A scene keeps what the file's displays can do: a part that names a display, a desktop, a
    /// slot or a drawer that is not there is dropped, the rest stays.
    private static func checked(_ scene: SharedScene, in displays: [SharedDisplay]) -> SharedScene {
        var result = SharedScene(name: clean(scene.name, fallback: "Scene"))
        for desktop in scene.desktops where displays.indices.contains(desktop.display)
            && displays[desktop.display].desktops.indices.contains(desktop.index)
            && !result.desktops.contains(where: { $0.display == desktop.display }) {
            result.desktops.append(desktop)
        }
        for focus in scene.focus {
            guard let desktop = result.desktops.first(where: { $0.display == focus.display }),
                  displays[desktop.display].desktops[desktop.index].layout?.slots.contains(where: { $0.id == focus.slotID }) == true,
                  !result.focus.contains(where: { $0.display == focus.display }) else { continue }
            result.focus.append(focus)
        }
        for drawer in scene.drawers where displays.indices.contains(drawer.display)
            && displays[drawer.display].drawers.contains(where: { $0.edge == drawer.edge })
            && !result.drawers.contains(where: { $0.display == drawer.display && $0.edge == drawer.edge }) {
            result.drawers.append(drawer)
        }
        for app in scene.apps.prefix(Limit.apps) where isBundleID(app) && !result.apps.contains(app) {
            result.apps.append(app)
        }
        return result
    }

    /// One line of text: no control character, no line break, cut at `Limit.text`.
    private static func clean(_ text: String, fallback: String) -> String {
        let scalars = text.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) && !CharacterSet.newlines.contains($0) }
        let line = String(String.UnicodeScalarView(scalars)).trimmingCharacters(in: .whitespaces)
        return line.isEmpty ? fallback : String(line.prefix(Limit.text))
    }

    private static let idCharacters = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")

    private static func isID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= Limit.id && text.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    private static func isBundleID(_ text: String) -> Bool {
        !text.isEmpty && text.count <= Limit.bundleID && text.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    private static func isUnit(_ rect: UnitRect) -> Bool {
        let slack = 0.001
        return [rect.x, rect.y, rect.w, rect.h].allSatisfy(\.isFinite) && rect.x >= -slack && rect.y >= -slack
            && rect.w > 0 && rect.h > 0 && rect.x + rect.w <= 1 + slack && rect.y + rect.h <= 1 + slack
    }
}

// MARK: - Adding to a configuration

/// What an import added, and what it could not.
public struct ImportReport: Equatable {
    public var desktops = 0
    public var drawers = 0
    public var scenes = 0
    /// Drawers of the file on an edge where the display already has one: the owner's stays.
    public var drawersKept = 0
    /// Displays of the file given no display here.
    public var displaysLeftOut = 0

    public init() {}
}

/// The displays the file's displays go to when the owner has not chosen: in order, one each.
public func defaultShareMapping(_ shared: SharedLayout, onto displays: [DisplayIdentity]) -> [Int: DisplayIdentity] {
    Dictionary(uniqueKeysWithValues: zip(shared.displays.indices, displays).map { ($0, $1) })
}

/// A configuration with a shared layout added beside what it has: on each display chosen
/// (`mapping`: position in the file, display here), the file's desktops come after the owner's,
/// its drawers on the edges still free, and its scenes follow with their desktops moved
/// accordingly. Nothing of the owner's is replaced. A display of the file left out takes its part
/// of the scenes with it.
public func adding(_ shared: SharedLayout, to configuration: Configuration,
                   onto mapping: [Int: DisplayIdentity]) -> (configuration: Configuration, report: ImportReport) {
    var result = configuration
    var report = ImportReport()
    /// Position in the file: the display here, and how many desktops it had before.
    var placed: [Int: (display: DisplayIdentity, offset: Int)] = [:]
    var taken: Set<DisplayIdentity> = []
    for (position, display) in shared.displays.enumerated() {
        guard let identity = mapping[position], taken.insert(identity).inserted,
              let index = result.displays.firstIndex(where: { $0.identity == identity && !$0.ignored }) else {
            report.displaysLeftOut += 1
            continue
        }
        placed[position] = (identity, result.displays[index].spaces.count)
        result.displays[index].spaces += display.desktops
        report.desktops += display.desktops.count
        for drawer in display.drawers {
            if result.displays[index].drawers.contains(where: { $0.edge == drawer.edge }) {
                report.drawersKept += 1
            } else {
                result.displays[index].drawers.append(drawer)
                report.drawers += 1
            }
        }
    }
    for scene in shared.scenes {
        var added = Scene(id: UUID(), name: scene.name, apps: scene.apps)
        for desktop in scene.desktops {
            guard let place = placed[desktop.display] else { continue }
            added.desktops.append(ConfiguredDesktop(display: place.display, index: place.offset + desktop.index))
        }
        for focus in scene.focus {
            guard let place = placed[focus.display], added.desktop(on: place.display) != nil else { continue }
            added.focus.append(SceneFocus(display: place.display, slotID: focus.slotID))
        }
        for drawer in scene.drawers {
            guard let place = placed[drawer.display] else { continue }
            added.drawers.append(SceneDrawer(display: place.display, edge: drawer.edge, open: drawer.open))
        }
        // A scene with nothing left to show or to move is not one.
        guard !added.desktops.isEmpty || !added.drawers.isEmpty else { continue }
        result.scenes.append(added)
        report.scenes += 1
    }
    return (result, report)
}
