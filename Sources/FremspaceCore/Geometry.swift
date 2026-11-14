import CoreGraphics
import Foundation

/// The clean fractions slot sizes snap to.
public enum Fractions {
    public static let stops: [Double] = [1.0 / 3, 0.4, 0.5, 0.6, 2.0 / 3, 1]

    /// The nearest stop (ties go to the smaller one).
    public static func snap(_ v: Double) -> Double {
        stops.min { abs($0 - v) < abs($1 - v) } ?? v
    }

    /// Displays at least this wide (points) also get eighths: ⅓ looks like ¼ on a 32".
    public static let eighthsFromWidth: CGFloat = 2560

    /// The stops for a display `width` points wide.
    public static func stops(forWidth width: CGFloat) -> [Double] {
        guard width >= eighthsFromWidth else { return stops }
        let eighths = (1...7).map { Double($0) / 8 }
        return Array(Set(stops + eighths)).sorted()
    }

    /// The nearest stop for a display `width` points wide (ties go to the smaller one).
    public static func snap(_ v: Double, width: CGFloat) -> Double {
        stops(forWidth: width).min { abs($0 - v) < abs($1 - v) } ?? v
    }
}

/// Converts an AppKit rectangle (origin bottom left of the primary display, y up) to the global
/// coordinates Accessibility uses (origin top left of the primary display, y down).
public func axRect(fromAppKit r: CGRect, primaryHeight: CGFloat) -> CGRect {
    CGRect(x: r.minX, y: primaryHeight - r.maxY, width: r.width, height: r.height)
}

/// The frame of every slot of `layout` on a display whose visible frame is `visible` (AX
/// coordinates). Slots keep `gap` from the screen edges and `gap / 2` from each other on every
/// inner side, so neighbours are `gap` apart. The focus slot, when set, takes the whole visible
/// frame inset by `gap`. Frames are rounded to whole points.
///
/// A free-form layout has no gap between its slots: each is the frame a window had, and a gap
/// taken off it would shrink the window a little more at every capture. Its focus slot keeps
/// the gap from the screen edges, as everywhere.
public func slotFrames(layout: Layout, focus: String?, visible: CGRect, gap: CGFloat) -> [String: CGRect] {
    var frames = unitFrames(layout.slots.filter { $0.id != focus }.map { (id: $0.id, rect: $0.rect) },
                            in: visible, gap: layout.freeForm ? 0 : gap)
    if let focus, layout.slots.contains(where: { $0.id == focus }) {
        frames[focus] = rounded(visible.insetBy(dx: gap, dy: gap))
    }
    return frames
}

/// The frame of each unit rectangle inside `container`: `gap` from the container's edges, `gap / 2`
/// on every inner side, rounded to whole points.
func unitFrames(_ rects: [(id: String, rect: UnitRect)], in container: CGRect, gap: CGFloat) -> [String: CGRect] {
    var frames: [String: CGRect] = [:]
    for (id, r) in rects {
        let minX = container.minX + CGFloat(r.x) * container.width
        let maxX = container.minX + CGFloat(r.x + r.w) * container.width
        let minY = container.minY + CGFloat(r.y) * container.height
        let maxY = container.minY + CGFloat(r.y + r.h) * container.height
        let left = isEdge(r.x) ? gap : gap / 2
        let right = isEdge(1 - (r.x + r.w)) ? gap : gap / 2
        let top = isEdge(r.y) ? gap : gap / 2
        let bottom = isEdge(1 - (r.y + r.h)) ? gap : gap / 2
        frames[id] = rounded(CGRect(x: minX + left, y: minY + top,
                                    width: maxX - right - (minX + left),
                                    height: maxY - bottom - (minY + top)))
    }
    return frames
}

/// The configuration's spec for a display, or nil when the display is unknown or ignored: either
/// way the display is free and nothing is placed on it.
public func displaySpec(for identity: DisplayIdentity, in configuration: Configuration) -> DisplaySpec? {
    guard let spec = configuration.displays.first(where: { $0.identity == identity }), !spec.ignored else {
        return nil
    }
    return spec
}

private func isEdge(_ distance: Double) -> Bool {
    abs(distance) < 0.001
}

/// Rounds both edges rather than origin and size, so adjacent frames stay adjacent.
private func rounded(_ r: CGRect) -> CGRect {
    let x0 = r.minX.rounded(), y0 = r.minY.rounded()
    return CGRect(x: x0, y: y0, width: r.maxX.rounded() - x0, height: r.maxY.rounded() - y0)
}
