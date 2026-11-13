import AppKit
import FremspaceCore

/// The menu bar glyph. Running, it draws the layout of the desktop the owner is on, the slot of the
/// window in front darker; one slot filling it while a slot is in Focus; an outline on a desktop
/// without layout. Otherwise the three slots of the app icon (scripts/make-icon.swift), with a pause
/// sign when paused. A template image, so it follows the menu bar's colours; the brand glyph is on
/// whole points, layouts on half points (sharp on a Retina display).
enum MenuBarIcon {
    static let size = NSSize(width: 18, height: 14)

    static func image(_ glyph: MenuGlyph) -> NSImage {
        let image = NSImage(size: size, flipped: true) { _ in
            switch glyph {
            case .brand: brand(paused: false)
            case .paused: brand(paused: true)
            case .free: outline()
            case .layout(let slots, let active): layout(slots, active: active)
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = glyph == .paused ? "Fremspace, paused" : "Fremspace"
        return image
    }

    private static func fill(_ rect: NSRect, _ alpha: CGFloat, radius: CGFloat = 2) {
        NSColor(white: 0, alpha: alpha).setFill()
        let r = min(radius, rect.width / 2, rect.height / 2)
        NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill()
    }

    /// Paused: the tall slot becomes the two bars of a pause sign and the other slots fade.
    private static func brand(paused: Bool) {
        let gap: CGFloat = 2, leftWidth: CGFloat = 9
        if paused {
            fill(NSRect(x: 0, y: 0, width: 3, height: size.height), 1, radius: 1.5)
            fill(NSRect(x: 6, y: 0, width: 3, height: size.height), 1, radius: 1.5)
        } else {
            fill(NSRect(x: 0, y: 0, width: leftWidth, height: size.height), 1)
        }
        let rightX = leftWidth + gap, rightWidth = size.width - rightX
        let half = (size.height - gap) / 2
        fill(NSRect(x: rightX, y: 0, width: rightWidth, height: half), paused ? 0.4 : 1)
        fill(NSRect(x: rightX, y: half + gap, width: rightWidth, height: half), paused ? 0.25 : 0.45)
    }

    private static func outline() {
        NSColor(white: 0, alpha: 0.85).setStroke()
        let path = NSBezierPath(roundedRect: NSRect(origin: .zero, size: size).insetBy(dx: 0.75, dy: 0.75), xRadius: 2.5, yRadius: 2.5)
        path.lineWidth = 1.5
        path.stroke()
    }

    private static func layout(_ slots: [UnitRect], active: Int?) {
        let gap: CGFloat = 1.5
        func snap(_ value: CGFloat) -> CGFloat { (value * 2).rounded() / 2 }
        for (index, slot) in slots.enumerated() {
            // Half a gap off every inner side; the outer sides reach the edge of the glyph.
            let x0 = CGFloat(slot.x) * size.width, x1 = CGFloat(slot.x + slot.w) * size.width
            let y0 = CGFloat(slot.y) * size.height, y1 = CGFloat(slot.y + slot.h) * size.height
            let left = snap(x0 <= 0.01 ? 0 : x0 + gap / 2), right = snap(x1 >= size.width - 0.01 ? size.width : x1 - gap / 2)
            let top = snap(y0 <= 0.01 ? 0 : y0 + gap / 2), bottom = snap(y1 >= size.height - 0.01 ? size.height : y1 - gap / 2)
            let rect = NSRect(x: left, y: top, width: max(1.5, right - left), height: max(1.5, bottom - top))
            // With no slot in front (a floating window has the keyboard) every slot is the same.
            fill(rect, active == nil ? 0.8 : (index == active ? 1 : 0.42), radius: 1.5)
        }
    }
}
