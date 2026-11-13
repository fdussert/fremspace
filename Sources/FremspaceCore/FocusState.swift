import Foundation

/// A Space: a display and the position of a desktop on it (full-screen Spaces not counted).
public struct SpaceKey: Hashable {
    public var display: DisplayIdentity
    public var spaceIndex: Int

    public init(display: DisplayIdentity, spaceIndex: Int) {
        self.display = display
        self.spaceIndex = spaceIndex
    }
}

/// Which slot, if any, is toggled to full screen on each Space.
public struct FocusState {
    private var active: [SpaceKey: String] = [:]

    public init() {}

    /// Toggles Focus of `slot` on `space`: off when that slot was focused, otherwise focuses it
    /// (switching from another slot if needed). Returns the slot focused afterwards.
    public mutating func toggle(_ space: SpaceKey, slot: String) -> String? {
        if active[space] == slot {
            active[space] = nil
        } else {
            active[space] = slot
        }
        return active[space]
    }

    /// Every focused slot, by Space (to save them).
    public var all: [SpaceKey: String] { active }

    /// Focuses `slot` on `space` (nil: none), without toggling: a Focus found again after a restart.
    public mutating func set(_ space: SpaceKey, slot: String?) {
        active[space] = slot
    }

    /// The focused slot of `space`, if any.
    public func slot(_ space: SpaceKey) -> String? {
        active[space]
    }
}

/// The slots in Focus by the desktop that shows each now, from what is kept by configured desktop
/// (`FocusedSlot`). Focus belongs to a configured desktop of a configuration: when macOS or the
/// owner reorders desktops it follows its desktop, and when another configuration applies (a
/// display unplugged) the Focus of the first one does not land on whatever desktop has the same
/// position. `real`: where a configured desktop is now, nil when it is not there; `hasSlot`:
/// whether that desktop still has that slot.
public func focusState(from kept: [FocusedSlot], configurationID: UUID, real: (ConfiguredDesktop) -> SpaceKey?,
                       hasSlot: (ConfiguredDesktop, String) -> Bool) -> FocusState {
    var state = FocusState()
    for entry in kept where entry.configurationID == configurationID && hasSlot(entry.desktop, entry.slotID) {
        if let space = real(entry.desktop) { state.set(space, slot: entry.slotID) }
    }
    return state
}

/// What to keep of the Focus once it changed: for `configurationID`, the slots in Focus now, each
/// under its configured desktop, and what was kept for the desktops that are not there at the
/// moment (a display unplugged, a desktop macOS no longer has), which come back with them. What
/// was kept for the other configurations stays as it is.
public func focusToKeep(_ focus: FocusState, kept: [FocusedSlot], configurationID: UUID,
                        configured: (SpaceKey) -> ConfiguredDesktop?, real: (ConfiguredDesktop) -> SpaceKey?) -> [FocusedSlot] {
    var result = kept.filter { $0.configurationID != configurationID || real($0.desktop) == nil }
    // In one order, so that the same Focus is not saved again as another list.
    let now = focus.all.compactMap { space, slot in
        configured(space).map { FocusedSlot(configurationID: configurationID, desktop: $0, slotID: slot) }
    }
    result += now.sorted {
        ($0.desktop.display.name, $0.desktop.display.serial, $0.desktop.index)
            < ($1.desktop.display.name, $1.desktop.display.serial, $1.desktop.index)
    }
    return result
}

/// What is kept of the Focus once configured desktop `index` of a display was removed (editor): its
/// own Focus goes with it, and the Focus of the desktops after it moves up with them.
public func focusKept(_ kept: [FocusedSlot], afterRemovingDesktop index: Int, of display: DisplayIdentity,
                      configuration: UUID) -> [FocusedSlot] {
    kept.compactMap { entry in
        guard entry.configurationID == configuration, entry.desktop.display == display else { return entry }
        if entry.desktop.index == index { return nil }
        var entry = entry
        if entry.desktop.index > index { entry.desktop.index -= 1 }
        return entry
    }
}

/// What is kept of the Focus once configured desktop `from` of a display was moved to position `to`
/// (editor): each Focus follows its desktop to the position it has now.
public func focusKept(_ kept: [FocusedSlot], afterMovingDesktop from: Int, to: Int, of display: DisplayIdentity,
                      configuration: UUID) -> [FocusedSlot] {
    kept.map { entry in
        guard entry.configurationID == configuration, entry.desktop.display == display else { return entry }
        var entry = entry
        entry.desktop.index = movedIndex(entry.desktop.index, from: from, to: to)
        return entry
    }
}

/// The slots of a desktop the Focus hotkey enlarges: those marked focusable, and the one a file
/// written before 2026-11-12 names as the desktop's Focus slot (there were two switches then).
public func focusSlots(_ space: SpaceSpec) -> [Slot] {
    space.layout?.slots.filter { $0.focusable || $0.id == space.focusSlot } ?? []
}

/// The slot the Focus hotkey acts on: the slot of the frontmost window when Focus enlarges it,
/// else the one of them furthest left (the highest of two at the same distance), so that the
/// hotkey does something from a window that is in none of them. `nil` on a free Space or one
/// without such a slot.
public func focusTarget(in space: SpaceSpec, frontmostSlot: String?) -> String? {
    let slots = focusSlots(space)
    if let frontmostSlot, slots.contains(where: { $0.id == frontmostSlot }) { return frontmostSlot }
    return slots.min { ($0.rect.x, $0.rect.y) < ($1.rect.x, $1.rect.y) }?.id
}

/// The desktop with Focus switched on or off for one slot. The file then only marks slots as
/// focusable: the desktop's own Focus slot of older files is folded into them.
public func settingFocus(_ space: SpaceSpec, slot id: String, on: Bool) -> SpaceSpec {
    guard var layout = space.layout else { return space }
    var ids = Set(focusSlots(space).map(\.id))
    if on { ids.insert(id) } else { ids.remove(id) }
    for index in layout.slots.indices { layout.slots[index].focusable = ids.contains(layout.slots[index].id) }
    var space = space
    space.layout = layout
    space.focusSlot = nil
    return space
}
