import CoreGraphics

/// The edge of the drawer a slot key (`"<edge>.<slot id>"`) belongs to.
public func drawerEdge(ofSlotKey key: String) -> String {
    String(key.prefix { $0 != "." })
}

/// Which windows the owner sent to which drawer, stacked per drawer slot, and which drawers are open.
/// A display has one drawer per edge; each opens and closes on its own.
public struct DrawerState {
    /// Per display, per drawer slot, members front first.
    private var stacksByDisplay: [DisplayIdentity: [String: [UInt32]]] = [:]
    /// Per display, the edges whose drawer is open.
    private var open: [DisplayIdentity: Set<String>] = [:]

    public init() {}

    /// Puts `id` on top of `slot`'s stack in a drawer of `display` (moving it if already a member).
    public mutating func send(_ id: UInt32, to display: DisplayIdentity, slot: String) {
        // Moving the only member to another slot empties the drawer for an instant: `remove` then
        // closes it, though the window is still shown; a member shown stays shown where it lands.
        let wasOpen = self.display(of: id) == display && self.slot(of: id).map { isOpen(display, edge: drawerEdge(ofSlotKey: $0)) } == true
        remove(id)
        stacksByDisplay[display, default: [:]][slot, default: []].insert(id, at: 0)
        if wasOpen { open[display, default: []].insert(drawerEdge(ofSlotKey: slot)) }
    }

    /// Takes `id` out of its drawer; a drawer left empty is closed. Returns its display.
    @discardableResult
    public mutating func remove(_ id: UInt32) -> DisplayIdentity? {
        guard let display = display(of: id), let slot = slot(of: id) else { return nil }
        stacksByDisplay[display]?[slot]?.removeAll { $0 == id }
        if stacksByDisplay[display]?[slot]?.isEmpty == true { stacksByDisplay[display]?[slot] = nil }
        if stacksByDisplay[display]?.isEmpty == true { stacksByDisplay[display] = nil }
        let edge = drawerEdge(ofSlotKey: slot)
        if stacks(display, edge: edge).isEmpty { setOpen(display, edge: edge, false) }
        return display
    }

    public func display(of id: UInt32) -> DisplayIdentity? {
        stacksByDisplay.first { $0.value.values.contains { $0.contains(id) } }?.key
    }

    public func slot(of id: UInt32) -> String? {
        for stacks in stacksByDisplay.values {
            if let slot = stacks.first(where: { $0.value.contains(id) })?.key { return slot }
        }
        return nil
    }

    public func stacks(_ display: DisplayIdentity) -> [String: [UInt32]] {
        stacksByDisplay[display] ?? [:]
    }

    /// The stacks of one drawer of `display`.
    public func stacks(_ display: DisplayIdentity, edge: String) -> [String: [UInt32]] {
        stacks(display).filter { drawerEdge(ofSlotKey: $0.key) == edge }
    }

    public mutating func bringToFront(_ id: UInt32) {
        guard let display = display(of: id), let slot = slot(of: id) else { return }
        stacksByDisplay[display]?[slot]?.removeAll { $0 == id }
        stacksByDisplay[display]?[slot]?.insert(id, at: 0)
    }

    /// The edges of `display` whose drawer is open.
    public func openEdges(_ display: DisplayIdentity) -> Set<String> {
        open[display] ?? []
    }

    /// Whether a drawer of `display` is open.
    public func isOpen(_ display: DisplayIdentity) -> Bool {
        !openEdges(display).isEmpty
    }

    public func isOpen(_ display: DisplayIdentity, edge: String) -> Bool {
        openEdges(display).contains(edge)
    }

    /// Whether the drawer holding member `id` is open.
    public func isShown(_ id: UInt32) -> Bool {
        guard let display = display(of: id), let slot = slot(of: id) else { return false }
        return isOpen(display, edge: drawerEdge(ofSlotKey: slot))
    }

    /// Opens or closes one drawer; a drawer without members cannot be open.
    public mutating func setOpen(_ display: DisplayIdentity, edge: String, _ isOpen: Bool) {
        if isOpen, !stacks(display, edge: edge).isEmpty {
            open[display, default: []].insert(edge)
        } else {
            open[display]?.remove(edge)
            if open[display]?.isEmpty == true { open[display] = nil }
        }
    }

    /// Opens (those holding members) or closes every drawer of `display`.
    public mutating func setOpen(_ display: DisplayIdentity, _ isOpen: Bool) {
        if isOpen {
            for edge in Set(stacks(display).keys.map(drawerEdge(ofSlotKey:))) { setOpen(display, edge: edge, true) }
        } else {
            open[display] = nil
        }
    }

    public var allMembers: [UInt32] {
        stacksByDisplay.values.flatMap { $0.values.flatMap { $0 } }
    }
}

public enum DrawerReaction: Equatable {
    /// Open the drawer of this edge.
    case open(DisplayIdentity, edge: String)
    /// Close every open drawer of the display.
    case close(DisplayIdentity)
    case none
}

/// What the activation of window `id` (on `display`) does to the drawers: a member opens its drawer
/// when it is closed; a window of the main layout closes the open drawers of its display.
public func drawerReaction(activated id: UInt32, on display: DisplayIdentity?, state: DrawerState,
                           isMainLayoutWindow: Bool) -> DrawerReaction {
    if let home = state.display(of: id), let slot = state.slot(of: id) {
        return state.isShown(id) ? .none : .open(home, edge: drawerEdge(ofSlotKey: slot))
    }
    if isMainLayoutWindow, let display, state.isOpen(display) { return .close(display) }
    return .none
}

/// The drawer slot (or any named frame) containing `point`.
public func slot(at point: CGPoint, in frames: [String: CGRect]) -> String? {
    frames.first { $0.value.contains(point) }?.key
}

public enum Direction {
    case left, right, up, down
}

/// The nearest slot (by centre) whose centre lies strictly on the given side of `slot`'s centre
/// (AX coordinates: up is smaller y). The slots that face it come first: those beside it for left
/// and right, above or below it for up and down, that is sharing part of its extent on the other
/// axis. Under a strip as wide as the display, the centre of the strip is nearer the left half
/// than the right half is, and "right" went up. Only when no slot faces it is the nearest of the
/// others taken, so that every slot of a sparse layout can still be reached. Two slots equally
/// near (a tall slot next to two stacked ones): the upper one, then the left one, so that the
/// answer does not change from one launch to the next.
public func neighbourSlot(from slot: String, toward: Direction, frames: [String: CGRect]) -> String? {
    guard let origin = frames[slot] else { return nil }
    let onThatSide = frames.filter { id, frame in
        guard id != slot else { return false }
        switch toward {
        case .right: return frame.midX > origin.midX
        case .left: return frame.midX < origin.midX
        case .down: return frame.midY > origin.midY
        case .up: return frame.midY < origin.midY
        }
    }
    let facing = onThatSide.filter { _, frame in
        switch toward {
        case .left, .right: return frame.minY < origin.maxY && frame.maxY > origin.minY
        case .up, .down: return frame.minX < origin.maxX && frame.maxX > origin.minX
        }
    }
    let candidates = facing.isEmpty ? onThatSide : facing
    func distance(_ r: CGRect) -> CGFloat { hypot(r.midX - origin.midX, r.midY - origin.midY) }
    return candidates.min { a, b in
        let da = distance(a.value), db = distance(b.value)
        if da != db { return da < db }
        if a.value.midY != b.value.midY { return a.value.midY < b.value.midY }
        if a.value.midX != b.value.midX { return a.value.midX < b.value.midX }
        return a.key < b.key
    }?.key
}

/// The regions the slot-navigation hotkeys move between: the open drawers' slots, and the layout's
/// slots except those mostly (half or more) under an open drawer zone.
public func visibleRegions(layout: [String: CGRect], drawers: [String: CGRect], drawerZones: [CGRect]) -> [String: CGRect] {
    var regions = layout.filter { _, frame in
        let covered = drawerZones.reduce(CGFloat(0)) { sum, zone in
            let i = zone.intersection(frame)
            return sum + (i.isNull ? 0 : i.width * i.height)
        }
        return covered < frame.width * frame.height / 2
    }
    for (key, frame) in drawers { regions[key] = frame }
    return regions
}
