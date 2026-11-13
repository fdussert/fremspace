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
