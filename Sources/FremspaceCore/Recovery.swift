import CoreGraphics

/// "Bring every window back on screen": nil when at least half of the window is on one display;
/// else the frame moved, as little as possible, inside the visible frame of the display it overlaps
/// most (the first display when none), its size clamped to that display.
public func onScreenFrame(_ frame: CGRect, displays: [CGRect]) -> CGRect? {
    func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
    let overlaps = displays.map { area($0.intersection(frame)) }
    if let best = overlaps.max(), best >= area(frame) / 2 { return nil }
    guard let target = zip(displays, overlaps).max(by: { $0.1 < $1.1 }).flatMap({ $0.1 > 0 ? $0.0 : nil })
            ?? displays.first else { return nil }
    let width = min(frame.width, target.width), height = min(frame.height, target.height)
    let x = min(max(frame.minX, target.minX), target.maxX - width)
    let y = min(max(frame.minY, target.minY), target.maxY - height)
    return CGRect(x: x, y: y, width: width, height: height)
}
