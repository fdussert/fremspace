import CoreGraphics

/// The drawer's zone on a display: full height of the visible frame, `size` of its width, at the edge.
public func drawerZone(_ drawer: DrawerSpec, visible: CGRect) -> CGRect {
    let width = (CGFloat(drawer.size) * visible.width).rounded()
    let x = drawer.edge == .left ? visible.minX : visible.maxX - width
    return CGRect(x: x, y: visible.minY, width: width, height: visible.height)
}

/// The frame of each drawer slot, with the same gaps as layout slots.
public func drawerFrames(_ drawer: DrawerSpec, visible: CGRect, gap: CGFloat) -> [String: CGRect] {
    unitFrames(drawer.layout.slots.map { (id: $0.id, rect: $0.rect) }, in: drawerZone(drawer, visible: visible), gap: gap)
}

/// The frames of the slots of several drawers of one desktop, keyed `"<edge>.<slot id>"` (e.g.
/// `"left.top"`), so the slots of a left and a right drawer never collide.
public func drawerFrames(_ drawers: [DrawerSpec], visible: CGRect, gap: CGFloat) -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for drawer in drawers {
        for (id, frame) in drawerFrames(drawer, visible: visible, gap: gap) {
            frames["\(drawer.edge.rawValue).\(id)"] = frame
        }
    }
    return frames
}

/// The drawer a slot key (`"<edge>.<slot id>"`) belongs to.
public func drawer(ofSlotKey key: String, in drawers: [DrawerSpec]) -> DrawerSpec? {
    guard let dot = key.firstIndex(of: "."), let edge = DrawerEdge(rawValue: String(key[..<dot])) else { return nil }
    return drawers.first { $0.edge == edge }
}

public enum ScreenSide: Hashable {
    case left, right, top, bottom
}

/// The sides of `display` with no other display against them (full frames, AX coordinates). A window
/// pushed through a side shared with another display moves to that display and its desktop.
public func freeSides(of display: CGRect, others: [CGRect]) -> Set<ScreenSide> {
    let near: CGFloat = 1
    func overlaps(_ a0: CGFloat, _ a1: CGFloat, _ b0: CGFloat, _ b1: CGFloat) -> Bool { min(a1, b1) - max(a0, b0) > 0 }
    var free: Set<ScreenSide> = [.left, .right, .top, .bottom]
    for o in others {
        let rows = overlaps(display.minY, display.maxY, o.minY, o.maxY)
        let columns = overlaps(display.minX, display.maxX, o.minX, o.maxX)
        if rows && abs(o.maxX - display.minX) <= near { free.remove(.left) }
        if rows && abs(o.minX - display.maxX) <= near { free.remove(.right) }
        if columns && abs(o.maxY - display.minY) <= near { free.remove(.top) }
        if columns && abs(o.minY - display.maxY) <= near { free.remove(.bottom) }
    }
    return free
}

/// The side drawer windows are parked through: the drawer's own edge if free, else the opposite
/// side, else the bottom. A left or right side hides a window down to 1 pt; the bottom keeps 32-52 pt
/// visible; the top is refused (spike `docs/spikes/2026-11-drawer-putaway.md`). The owner wants
/// parked windows hidden completely.
public func parkSide(for edge: DrawerEdge, free: Set<ScreenSide>) -> ScreenSide? {
    let own: ScreenSide = edge == .left ? .left : .right
    let opposite: ScreenSide = edge == .left ? .right : .left
    return [own, opposite, .bottom].first { free.contains($0) }
}

/// `frame` moved through `side` of `display` so that `strip` points stay inside it.
public func parkedFrame(_ frame: CGRect, display: CGRect, side: ScreenSide, strip: CGFloat) -> CGRect {
    var f = frame
    switch side {
    case .left: f.origin.x = display.minX - frame.width + strip
    case .right: f.origin.x = display.maxX - strip
    case .top: f.origin.y = display.minY - frame.height + strip
    case .bottom: f.origin.y = display.maxY - strip
    }
    return f
}

/// `frame` parked through the left or right side of `display` (the drawer's own side first) so that
/// nothing but `strip` points of it is over a display. A side with another display against part of
/// it still works (a laptop lower than the monitor beside it): the window goes just under that
/// display, along the stretch that is free, and may run past the bottom of `display`. nil when
/// neither side takes the window; the bottom, which keeps a title bar visible, is then all that is left.
public func hiddenParkedFrame(_ frame: CGRect, display: CGRect, others: [CGRect], edge: DrawerEdge,
                              strip: CGFloat) -> CGRect? {
    let sides: [ScreenSide] = edge == .left ? [.left, .right] : [.right, .left]
    // Against the display over at least this height, so that macOS keeps the window on it.
    let hold = min(frame.height, 100)
    for side in sides {
        let base = parkedFrame(frame, display: display, side: side, strip: strip)
        // Where it is, else just under a display that is in the way. Never above the display's top:
        // macOS refuses a title bar there.
        for top in [base.minY] + others.map(\.maxY).sorted() where top >= display.minY && top + hold <= display.maxY {
            var parked = base
            parked.origin.y = top
            var hidden = parked
            hidden.size.width -= strip
            if side == .right { hidden.origin.x += strip }
            if !others.contains(where: { $0.intersects(hidden) }) { return parked }
        }
    }
    return nil
}

/// Like `parkedFrame`, narrowed to `width` and kept `gap` from the drawer's edge of the display: through
/// the bottom macOS keeps a parked window's title bar visible, so it shrinks to a small tab in the
/// drawer's corner.
public func compactParkedFrame(_ frame: CGRect, display: CGRect, side: ScreenSide, strip: CGFloat,
                               edge: DrawerEdge, width: CGFloat, gap: CGFloat) -> CGRect {
    var f = parkedFrame(frame, display: display, side: side, strip: strip)
    f.size.width = width
    f.origin.x = edge == .left ? display.minX + gap : display.maxX - gap - width
    return f
}
