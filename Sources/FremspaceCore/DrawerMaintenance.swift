import CoreGraphics
import Foundation

/// Whether a drawer member was closed. Only answerable when the desktop it is on is the one shown (Accessibility
/// lists the current desktop only) and its app is not hidden (a hidden app's windows are off screen but
/// alive): then a window missing from its app's window list is gone. Anything else keeps the member,
/// so a parked window is never let go by mistake.
public func memberIsGone(spaceIsShown: Bool, appHidden: Bool, inAppWindowList: Bool) -> Bool {
    spaceIsShown && !appHidden && !inAppWindowList
}

/// Whether what an app lists as its windows can tell a member closed. Behind the lock screen, and
/// for a moment after it, every app answers Accessibility with no window at all while its windows
/// live on: an empty list from an app whose drawer members the window server still shows
/// (`onScreen`: those of its members that are on screen) is no answer, like a timeout. A member
/// that was closed, or hidden instead of destroyed, is not shown there either. Only the members
/// count: an app may keep a window of its own on screen that Accessibility never lists.
public func windowListAnswers(listed: Set<UInt32>, onScreen: Set<UInt32>) -> Bool {
    !listed.isEmpty || onScreen.isEmpty
}

/// Members whose drawer slot no longer exists in the configuration (a reload removed or renamed it).
public func staleMembers(_ state: DrawerState, validKeys: (DisplayIdentity) -> Set<String>) -> [UInt32] {
    state.allMembers.filter { id in
        guard let display = state.display(of: id), let slot = state.slot(of: id) else { return true }
        return !validKeys(display).contains(slot)
    }
}

/// Which members to bring back on screen now, and which to keep for later: a member whose display is
/// not connected stays a member (macOS usually puts its window back, parked, when the display returns).
public func restorePlan(_ state: DrawerState, connected: Set<DisplayIdentity>) -> (restore: [UInt32], keep: [UInt32]) {
    var restore: [UInt32] = [], keep: [UInt32] = []
    for id in state.allMembers.sorted() {
        if let display = state.display(of: id), connected.contains(display) { restore.append(id) } else { keep.append(id) }
    }
    return (restore, keep)
}

/// Members to send to the desktop their display shows now: a drawer belongs to its display, so its
/// windows follow the desktop the owner looks at. `shown` is the desktop each display shows (a display
/// on a full-screen Space is absent: nothing follows there), `location` where a window is. A member
/// macOS moved to another display, or one whose place cannot be read, is left alone.
public func membersToBring(_ state: DrawerState, shown: [DisplayIdentity: Int],
                           location: (UInt32) -> SpaceKey?) -> [(id: UInt32, to: SpaceKey)] {
    state.allMembers.sorted().compactMap { id in
        guard let display = state.display(of: id), let index = shown[display], let here = location(id),
              here.display == display, here.spaceIndex != index else { return nil }
        return (id, SpaceKey(display: display, spaceIndex: index))
    }
}

/// `drawerReaction`, plus: an activated member becomes the front of its drawer slot, so the window the
/// owner picked (⌘Tab) is the one shown.
public func activate(_ id: UInt32, on display: DisplayIdentity?, state: inout DrawerState, isMainLayoutWindow: Bool) -> DrawerReaction {
    let reaction = drawerReaction(activated: id, on: display, state: state, isMainLayoutWindow: isMainLayoutWindow)
    if state.display(of: id) != nil { state.bringToFront(id) }
    return reaction
}

/// The members to keep in the parked file: those of a closed drawer, and those that were to come
/// back on screen and whose window could not be moved (its app did not answer in time). Such a
/// window is still off screen whatever its drawer says: left out of the file, nothing would bring
/// it back once Fremspace has quit.
public func parkedMembers(_ state: DrawerState, notBroughtBack: Set<UInt32>) -> [UInt32] {
    state.allMembers.filter { !state.isShown($0) || notBroughtBack.contains($0) }.sorted()
}

/// A window Fremspace pushed off screen (a closed drawer's member), and the frame that brings it back.
public struct ParkedWindow: Codable, Equatable {
    public var id: UInt32
    public var pid: Int32
    public var bundleID: String
    public var frame: CGRect

    public init(id: UInt32, pid: Int32, bundleID: String, frame: CGRect) {
        self.id = id
        self.pid = pid
        self.bundleID = bundleID
        self.frame = frame
    }
}

/// The parked windows, kept on disk next to the configuration so that a crash (which skips every
/// handler) never leaves a window off screen: the next launch brings them back.
public enum ParkedFile {
    /// Missing or unreadable: nothing parked.
    public static func load(_ url: URL) -> [ParkedWindow] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([ParkedWindow].self, from: data)) ?? []
    }

    /// When the file was last written, nil when there is none.
    public static func savedAt(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public static func save(_ parked: [ParkedWindow], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(parked).write(to: url, options: .atomic)
    }
}

/// Which saved parked windows to bring back: those still alive in the same process (`alive`: window
/// id → owner pid), when that process is still the same app (`app`: the bundle id of a process,
/// nil when it has none, saved as "?"). Anything else is dropped (closed, or its id reused by
/// another process or another app).
public func recoveryPlan(saved: [ParkedWindow], alive: [UInt32: Int32],
                         app: (Int32) -> String?) -> (restore: [ParkedWindow], drop: [UInt32]) {
    var restore: [ParkedWindow] = [], drop: [UInt32] = []
    for window in saved {
        if alive[window.id] == window.pid, (app(window.pid) ?? "?") == window.bundleID {
            restore.append(window)
        } else {
            drop.append(window.id)
        }
    }
    return (restore, drop)
}

/// The apps that have a slot in a layout of configuration `id` in `after` and had none in `before`:
/// what the owner just gave a slot to. Their windows put in a drawer by hand leave it, or saving
/// the slot would change nothing on screen. Empty when the configuration is new: nothing was
/// given there, it all arrived at once.
public func appsGivenASlot(before: Config, after: Config, configuration id: UUID) -> Set<String> {
    func apps(_ config: Config) -> Set<String>? {
        guard let configuration = config.configurations.first(where: { $0.id == id }) else { return nil }
        var found: Set<String> = []
        for display in configuration.displays where !display.ignored {
            for space in display.spaces {
                for slot in space.layout?.slots ?? [] {
                    found.formUnion(slot.rules.map(\.bundleID).filter { !$0.isEmpty })
                }
            }
        }
        return found
    }
    guard let had = apps(before), let has = apps(after) else { return [] }
    return has.subtracting(had)
}
