import CoreGraphics

/// A starting layout from the windows of a desktop, front to back: each manageable window becomes a
/// slot whose edges are snapped to clean fractions of `visible` (eighths on large displays). Windows
/// of the same app on the same snapped rectangle stack in one slot; a window overlapping a slot
/// already taken (by a window in front of it) is dropped, so slots never overlap.
public func capture(windows: [(info: WindowInfo, frame: CGRect)], visible: CGRect) -> Layout {
    var slots: [Slot] = []
    for (info, frame) in windows where info.isManageable {
        guard let rect = snappedRect(frame, visible: visible) else { continue }
        if slots.contains(where: { $0.rule.bundleID == info.bundleID && $0.rect == rect }) { continue }
        if slots.contains(where: { overlaps($0.rect, rect) }) { continue }
        var rule = Rule(bundleID: info.bundleID)
        rule.profile = info.profile
        slots.append(Slot(id: uniqueID(for: info.bundleID, among: slots.map(\.id)), rect: rect, rule: rule))
    }
    return Layout(slots: slots)
}

/// A free-form layout from the windows of a desktop, front to back: each manageable window becomes
/// a slot at the place it has, to a thousandth of `visible`, over the others when it is. Nothing
/// is snapped or dropped. The slots are not locked: the windows go back there whenever Fremspace
/// places the windows again (a display plugged in again, a login, ⌃⌥⌘R) and stay where the owner
/// drags them meanwhile. Two windows of one app and profile at the very same place share a slot.
public func captureFreeForm(windows: [(info: WindowInfo, frame: CGRect)], visible: CGRect) -> Layout {
    guard visible.width > 0, visible.height > 0 else { return Layout(slots: [], freeForm: true) }
    func unit(_ value: CGFloat) -> Double { (Double(value) * 1000).rounded() / 1000 }
    var slots: [Slot] = []
    for (info, frame) in windows where info.isManageable {
        // The part of the window that is on this display: a window hanging off it is kept as far as it shows.
        let shown = frame.intersection(visible)
        guard !shown.isNull, shown.width >= 1, shown.height >= 1 else { continue }
        let rect = UnitRect(x: unit((shown.minX - visible.minX) / visible.width), y: unit((shown.minY - visible.minY) / visible.height),
                            w: unit(shown.width / visible.width), h: unit(shown.height / visible.height))
        guard rect.w > 0, rect.h > 0 else { continue }
        var rule = Rule(bundleID: info.bundleID)
        rule.profile = info.profile
        if slots.contains(where: { $0.rect == rect && $0.rules.contains(rule) }) { continue }
        slots.append(Slot(id: uniqueID(for: info.bundleID, among: slots.map(\.id)), rect: rect, rule: rule, locked: false))
    }
    return Layout(slots: slots, freeForm: true)
}

/// A frame as a unit rectangle of `visible`, its edges snapped to the editor's fractions (eighths on
/// large displays); nil when it snaps to nothing (too small).
public func snappedRect(_ frame: CGRect, visible: CGRect) -> UnitRect? {
    func edge(_ value: CGFloat, _ origin: CGFloat, _ length: CGFloat) -> Double {
        let positions = [0.0] + Fractions.stops(forWidth: visible.width)
        let v = Double((value - origin) / length)
        return positions.min { abs($0 - v) < abs($1 - v) } ?? v
    }
    let left = edge(frame.minX, visible.minX, visible.width), right = edge(frame.maxX, visible.minX, visible.width)
    let top = edge(frame.minY, visible.minY, visible.height), bottom = edge(frame.maxY, visible.minY, visible.height)
    guard right > left, bottom > top else { return nil }
    return UnitRect(x: left, y: top, w: right - left, h: bottom - top)
}

/// Whether two unit rectangles share some area (touching edges do not count).
func overlaps(_ a: UnitRect, _ b: UnitRect) -> Bool {
    let e = 1e-9
    return a.x < b.x + b.w - e && b.x < a.x + a.w - e && a.y < b.y + b.h - e && b.y < a.y + a.h - e
}

/// "vscode", "browser"…, then "browser-2" when taken.
func uniqueID(for bundleID: String, among taken: [String]) -> String {
    let base = bundleID.split(separator: ".").last.map { String($0).lowercased() } ?? "slot"
    if !taken.contains(base) { return base }
    var n = 2
    while taken.contains("\(base)-\(n)") { n += 1 }
    return "\(base)-\(n)"
}
