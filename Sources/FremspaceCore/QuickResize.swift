import CoreGraphics

/// Rectangle's basic commands for the active window.
public enum QuickResize: String, CaseIterable {
    case leftHalf, rightHalf, topHalf, bottomHalf, maximize, center
    case firstThird, centerThird, lastThird, firstTwoThirds, lastTwoThirds
}

/// The frame of `command` on a display whose visible frame is `visible` (AX coordinates), without
/// gaps (Rectangle's default). Thirds are columns on a landscape display, rows on a portrait one.
/// `center` keeps the window's size, clamped to the display.
public func quickFrame(_ command: QuickResize, window: CGRect, visible v: CGRect) -> CGRect {
    let landscape = v.width >= v.height
    /// The part of the display from `start` to `end` (fractions) along its long side.
    func band(_ start: CGFloat, _ end: CGFloat) -> CGRect {
        landscape
            ? CGRect(x: v.minX + v.width * start, y: v.minY, width: v.width * (end - start), height: v.height)
            : CGRect(x: v.minX, y: v.minY + v.height * start, width: v.width, height: v.height * (end - start))
    }
    let frame: CGRect
    switch command {
    case .leftHalf: frame = CGRect(x: v.minX, y: v.minY, width: v.width / 2, height: v.height)
    case .rightHalf: frame = CGRect(x: v.midX, y: v.minY, width: v.width / 2, height: v.height)
    case .topHalf: frame = CGRect(x: v.minX, y: v.minY, width: v.width, height: v.height / 2)
    case .bottomHalf: frame = CGRect(x: v.minX, y: v.midY, width: v.width, height: v.height / 2)
    case .maximize: frame = v
    case .center:
        let width = min(window.width, v.width), height = min(window.height, v.height)
        frame = CGRect(x: v.midX - width / 2, y: v.midY - height / 2, width: width, height: height)
    case .firstThird: frame = band(0, 1.0 / 3)
    case .centerThird: frame = band(1.0 / 3, 2.0 / 3)
    case .lastThird: frame = band(2.0 / 3, 1)
    case .firstTwoThirds: frame = band(0, 2.0 / 3)
    case .lastTwoThirds: frame = band(1.0 / 3, 1)
    }
    // Both edges are rounded, not origin and size: on an odd-sized display two halves would
    // otherwise overlap, or end one point past the visible frame.
    let x0 = frame.minX.rounded(), y0 = frame.minY.rounded()
    return CGRect(x: x0, y: y0, width: frame.maxX.rounded() - x0, height: frame.maxY.rounded() - y0)
}
