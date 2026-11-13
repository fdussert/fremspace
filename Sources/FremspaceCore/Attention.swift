import Foundation

/// How much one line of the Status page matters: Fremspace does nothing, does less than set up, or
/// just says so.
public enum AttentionLevel: Int, Comparable {
    case blocking, warning, note

    public static func < (a: AttentionLevel, b: AttentionLevel) -> Bool { a.rawValue < b.rawValue }
}

/// What the button of a line does.
public enum AttentionFix: Equatable {
    case openAccessibilitySettings
    case openDesktopSettings
    case openScreenRecordingSettings
    case openConfigFile
    case resume
    case newConfiguration
    case addDesktops
    case addFreeDesktop(UUID)
    case showShortcuts
    case showDesktop(configuration: UUID, display: DisplayIdentity, desktop: Int, slot: String)
}

/// One thing that needs the owner: what, why it matters, and the way out when there is one.
public struct AttentionItem: Equatable {
    public var id: String
    public var level: AttentionLevel
    public var title: String
    public var detail: String
    public var fix: AttentionFix?

    public init(id: String, level: AttentionLevel, title: String, detail: String, fix: AttentionFix? = nil) {
        self.id = id
        self.level = level
        self.title = title
        self.detail = detail
        self.fix = fix
    }
}

/// Why no configuration is applied.
public enum AttentionIdle: Equatable {
    /// No configuration lists the displays connected now.
    case noConfiguration
    /// Anything else, in the engine's words.
    case other(String)
}

/// What Fremspace knows about itself and the Mac, read by the app when the Status page is shown.
public struct AttentionFacts {
    public var accessibility = true
    /// The config file exists and cannot be read.
    public var loadError: String?
    public var paused = false
    /// Set while no configuration is applied for another reason than the three above.
    public var idle: AttentionIdle?
    public var sessionLocked = false
    public var config = Config(configurations: [])
    /// The configuration applied now.
    public var active: UUID?
    /// Desktops of each connected display.
    public var desktopCounts: [DisplayIdentity: Int] = [:]
    /// Apps with a slot that are not on this Mac.
    public var missingApps: Set<String> = []
    /// The shortcuts another app holds, as they are written ("⌃⌥⌘K").
    public var takenShortcuts: [String] = []
    /// The key filter of the Hyper key is in place.
    public var hyperOn = false
    /// Sending a window to another desktop works (see `MoverHealth`).
    public var moverAvailable = true
    /// The operation that sends a window to another desktop is not on this macOS.
    public var moverMissing = false
    /// Drawer windows Fremspace knows of and cannot read yet.
    public var waitingDrawerWindows = 0
    /// "Displays have separate Spaces" is off.
    public var spacesSpanDisplays = false
    /// `SpacesOrder.warning`, when macOS reorders desktops.
    public var spacesOrderWarning: String?
    /// macOS lets Fremspace take pictures of windows (the Screen Recording permission).
    public var screenRecording = false
    /// The private calls that are not on this macOS (see `PrivateCall`).
    public var missingCalls: [PrivateCall] = []

    public init() {}
}

/// The lines of the Status page, most serious first. Empty: nothing needs the owner.
public func attentionItems(_ facts: AttentionFacts) -> [AttentionItem] {
    var items: [AttentionItem] = []
    func add(_ id: String, _ level: AttentionLevel, _ title: String, _ detail: String, _ fix: AttentionFix? = nil) {
        items.append(AttentionItem(id: id, level: level, title: title, detail: detail, fix: fix))
    }

    if !facts.accessibility {
        add("accessibility", .blocking, "Fremspace cannot read or move windows",
            "It needs Accessibility: System Settings \u{2192} Privacy & Security \u{2192} Accessibility, then switch Fremspace on.",
            .openAccessibilitySettings)
    }
    if let loadError = facts.loadError {
        add("configFile", .blocking, "The config file cannot be read",
            "\(loadError) Nothing is applied and nothing can be saved until it is fixed by hand.", .openConfigFile)
    }
    if facts.spacesSpanDisplays {
        add("spansDisplays", .blocking, "macOS shows one desktop across every display",
            "Fremspace needs \u{201C}Displays have separate Spaces\u{201D} (Desktop & Dock \u{2192} Mission Control). macOS applies it after you log out.",
            .openDesktopSettings)
    }
    if facts.paused {
        add("paused", .warning, "Fremspace is paused", "Nothing is moved until you resume.", .resume)
    }
    let lost = Set(facts.missingCalls.map(\.loss))
    func names(_ loss: PrivateCallLoss) -> String {
        PrivateCall.allCases.filter { $0.loss == loss && facts.missingCalls.contains($0) }.map(\.rawValue).joined(separator: ", ")
    }
    if lost.contains(.placing) {
        add("calls.placing", .blocking, "A macOS update removed something Fremspace needs",
            "It can no longer read desktops and windows (\(names(.placing))). Nothing is applied until Fremspace is updated: Check for Updates\u{2026} in its menu.")
    }
    if facts.accessibility, facts.loadError == nil, !facts.paused, !lost.contains(.placing), let idle = facts.idle {
        switch idle {
        case .noConfiguration where facts.config.configurations.isEmpty:
            add("idle", .warning, "No configuration yet",
                "A configuration holds the layouts for one set of displays. Until there is one, windows stay where they are.", .newConfiguration)
        case .noConfiguration:
            add("idle", .warning, "No configuration for the displays connected now",
                "Windows stay where they are. Make one for these displays, or mark the display that is missing as optional in a configuration.",
                .newConfiguration)
        case .other(let reason):
            add("idle", .warning, "No configuration is applied", reason + ".")
        }
    }
    if facts.moverMissing {
        add("mover", .warning, "This macOS cannot send a window to another desktop",
            "It needs macOS 26.4 or later: the part of macOS that Fremspace does it with is not on this Mac. A window stays on the desktop where it opens, is not put back on its desktop after a restart, and a drawer does not follow its display to another desktop.")
    } else if !facts.moverAvailable {
        add("mover", .warning, "Windows can no longer be sent to another desktop",
            "macOS refused the last moves. A window stays on the desktop where it opens; Re-apply the layouts tries again.")
    }
    if let warning = facts.spacesOrderWarning {
        add("spacesOrder", .warning, "macOS reorders your desktops", warning + ".", .openDesktopSettings)
    }

    let active = facts.config.configurations.first { $0.id == facts.active }
    if let active {
        for missing in missingDesktops(active, present: facts.desktopCounts) {
            let count = missing.needed - missing.present
            add("desktops.\(missing.display.name)", .warning,
                "\(active.displayName(missing.display)) is \(count) desktop\(count == 1 ? "" : "s") short",
                "\u{201C}\(active.name)\u{201D} lists \(missing.needed) there and macOS has \(missing.present): the layouts of the last ones are not applied.",
                .addDesktops)
        }
        let hasFree = active.displays.contains { !$0.ignored && $0.spaces.contains { $0.layout == nil } }
        if facts.config.noFloating, !hasFree {
            add("noFreeDesktop", .warning, "Windows without a slot have nowhere to go",
                "\u{201C}No floating windows on layout desktops\u{201D} is on and \u{201C}\(active.name)\u{201D} has no free desktop, so they stay where they are.",
                .addFreeDesktop(active.id))
        }
    }
    if !facts.takenShortcuts.isEmpty {
        let count = facts.takenShortcuts.count
        add("shortcuts", .warning, count == 1 ? "A shortcut is taken by another app" : "\(count) shortcuts are taken by another app",
            "\(facts.takenShortcuts.joined(separator: ", ")) \(count == 1 ? "does" : "do") nothing in Fremspace. Choose another, or free \(count == 1 ? "it" : "them") in the other app.",
            .showShortcuts)
    }
    if facts.config.hyperKey, lost.contains(.hyperKey) {
        add("calls.hyperKey", .warning, "Caps Lock cannot be the Hyper key on this macOS",
            "The setting is on and does nothing: macOS no longer has what remaps a key (\(names(.hyperKey))).")
    } else if facts.config.hyperKey, !facts.hyperOn, facts.accessibility {
        add("hyper", .warning, "Caps Lock is not the Hyper key",
            "The setting is on and the key filter could not be installed, so Caps Lock is itself. If macOS asks, allow Fremspace under Privacy & Security.",
            .openAccessibilitySettings)
    }

    if facts.config.windowPreviews, !facts.screenRecording {
        add("previews", .warning, "Window previews are on and macOS does not allow them",
            "They need Screen Recording: System Settings \u{2192} Privacy & Security \u{2192} Screen & System Audio Recording, then switch Fremspace on. macOS asks to quit and reopen Fremspace. Until then the palette and the maps show app icons.",
            .openScreenRecordingSettings)
    }

    if let active {
        var seen: Set<String> = []
        for display in active.displays where !display.ignored {
            for (index, space) in display.spaces.enumerated() {
                for slot in space.layout?.slots ?? [] {
                    for rule in slot.rules where facts.missingApps.contains(rule.bundleID) && seen.insert(rule.bundleID).inserted {
                        add("app.\(rule.bundleID)", .note, "\(rule.bundleID) has a slot and is not on this Mac",
                            "Its slot on \u{201C}\(space.label)\u{201D} (\(display.displayName)) stays empty.",
                            .showDesktop(configuration: active.id, display: display.identity, desktop: index, slot: slot.id))
                    }
                }
            }
        }
    }
    if lost.contains(.oneWindowForward) {
        add("calls.oneWindowForward", .note, "A window comes forward with the other windows of its app",
            "macOS no longer has what brings one window forward alone (\(names(.oneWindowForward))).")
    }
    if lost.contains(.addingDesktops) {
        add("calls.addingDesktops", .note, "Fremspace cannot add desktops on this macOS",
            "It no longer has what opens Mission Control (\(names(.addingDesktops))). Add them there yourself: the + at the top right of each display.")
    }
    if facts.waitingDrawerWindows > 0 {
        let count = facts.waitingDrawerWindows
        add("drawerWaiting", .note, count == 1 ? "A drawer window is not back yet" : "\(count) drawer windows are not back yet",
            facts.sessionLocked
                ? "They cannot be read while the screen is locked; they rejoin their drawer when you unlock."
                : "They were in a drawer when Fremspace started and cannot be read yet. \u{201C}Bring every window back on screen\u{201D} in Maintenance fetches them.")
    }
    // Stable: the order above within a level.
    return items.enumerated().sorted { ($0.element.level, $0.offset) < ($1.element.level, $1.offset) }.map(\.element)
}
