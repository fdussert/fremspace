import CoreGraphics

/// "Lock on this desktop": the window's current frame becomes a locked slot for its app (and
/// profile). A window over existing slots joins the one it overlaps most (that slot then takes this
/// app too); else a new slot, snapped to the editor's grid. No layout (a free desktop) gets a layout
/// with that one slot. Nil when the frame snaps to nothing.
public func lockHere(layout: Layout?, window: WindowInfo, frame: CGRect, visible: CGRect) -> (layout: Layout, slotID: String)? {
    let rule = Rule(bundleID: window.bundleID, profile: window.profile)
    var layout = layout ?? Layout(slots: [])
    let unit = UnitRect(x: Double((frame.minX - visible.minX) / visible.width),
                        y: Double((frame.minY - visible.minY) / visible.height),
                        w: Double(frame.width / visible.width), h: Double(frame.height / visible.height))
    let overlapped = layout.slots.indices
        .map { (index: $0, area: overlapArea(layout.slots[$0].rect, unit)) }
        .filter { $0.area > 0.0001 }
        .max { $0.area < $1.area }
    if let overlapped {
        if !layout.slots[overlapped.index].rules.contains(rule) { layout.slots[overlapped.index].rules.append(rule) }
        return (layout, layout.slots[overlapped.index].id)
    }
    guard let rect = snappedRect(frame, visible: visible) else { return nil }
    let id = uniqueID(for: window.bundleID, among: layout.slots.map(\.id))
    layout.slots.append(Slot(id: id, rect: rect, rule: rule, locked: true))
    return (layout, id)
}

/// The slot's "Focusable" option switched.
public func toggledFocusable(_ layout: Layout, slot: String) -> Layout {
    var layout = layout
    if let index = layout.slots.firstIndex(where: { $0.id == slot }) { layout.slots[index].focusable.toggle() }
    return layout
}

private func overlapArea(_ a: UnitRect, _ b: UnitRect) -> Double {
    let w = min(a.x + a.w, b.x + b.w) - max(a.x, b.x)
    let h = min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
    return w > 0 && h > 0 ? w * h : 0
}
