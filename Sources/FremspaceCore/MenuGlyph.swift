import Foundation

/// What the menu bar glyph draws.
public enum MenuGlyph: Equatable {
    /// The three slots of the app icon: Fremspace is not running a configuration.
    case brand
    case paused
    /// The desktop the owner is on has no layout.
    case free
    /// The layout of the desktop the owner is on; `active` is the slot holding the window in front.
    case layout(slots: [UnitRect], active: Int?)
}

/// The glyph for the desktop the owner is on: its layout as it is on screen now (one slot filling the
/// desktop while a slot is in Focus), with the slot of the window in front told apart.
public func menuGlyph(running: Bool, paused: Bool, layout: Layout?, focusedSlot: String?, activeSlot: String?) -> MenuGlyph {
    if paused { return .paused }
    guard running else { return .brand }
    guard let layout, !layout.slots.isEmpty else { return .free }
    if let focusedSlot, layout.slots.contains(where: { $0.id == focusedSlot }) {
        return .layout(slots: [UnitRect(x: 0, y: 0, w: 1, h: 1)], active: activeSlot == focusedSlot ? 0 : nil)
    }
    return .layout(slots: layout.slots.map(\.rect), active: layout.slots.firstIndex { $0.id == activeSlot })
}
