import CoreGraphics
import Foundation

/// The displays that changed desktop between two readings of "display → desktop shown". A display
/// that was not in the first reading (just connected, or back from a full-screen Space) says nothing:
/// its desktop did not change under the owner's eyes.
public func changedDesktops(from old: [DisplayIdentity: Int], to new: [DisplayIdentity: Int]) -> [DisplayIdentity] {
    new.compactMap { display, index in
        guard let before = old[display], before != index else { return nil }
        return display
    }
    .sorted { $0.name < $1.name }
}

/// What the banner says about the desktop a display now shows.
public struct DesktopBanner: Equatable {
    public var label: String
    /// Desktops of the display, and the position of the one shown.
    public var count: Int
    public var index: Int

    public init(label: String, count: Int, index: Int) {
        self.label = label
        self.count = count
        self.index = index
    }
}

/// The banner for the desktop at `index` (macOS's order) of a display with `count` desktops:
/// its configured label, else its number.
public func desktopBanner(label: String?, index: Int, count: Int) -> DesktopBanner {
    let name = label.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 } ?? "Desktop \(index + 1)"
    return DesktopBanner(label: name, count: max(count, index + 1), index: index)
}

/// Where things hang at the top of a display, in AppKit screen coordinates (y goes up). A display
/// with a notch (a camera housing cut into the top of the screen) has no pixels there: what hangs
/// from it starts at the top edge, as wide as the notch at least, and shows its content under it.
public struct NotchGeometry: Equatable {
    public var screen: CGRect
    /// The notch, nil on a display without one.
    public var notch: CGRect?
    /// The height of the menu bar on a display without a notch.
    public var menuBar: CGFloat

    /// `safeTop`: the height the notch takes at the top (0 without one). `left` and `right`: the
    /// widths of the screen beside the notch, as AppKit reports them.
    public init(screen: CGRect, safeTop: CGFloat, left: CGFloat?, right: CGFloat?, menuBar: CGFloat = 24) {
        self.screen = screen
        self.menuBar = menuBar
        if safeTop > 0, let left, let right, screen.width - left - right > 0 {
            notch = CGRect(x: screen.minX + left, y: screen.maxY - safeTop, width: screen.width - left - right, height: safeTop)
        } else {
            notch = nil
        }
    }

    /// The frame of something hanging at the top with `content` to show: from the notch (the content
    /// under it, the whole at least as wide as the notch), else centred a little under the menu bar.
    /// Kept inside the screen.
    public func hanging(content: CGSize, gap: CGFloat = 6) -> CGRect {
        var frame: CGRect
        if let notch {
            let width = max(notch.width, content.width)
            frame = CGRect(x: notch.midX - width / 2, y: notch.minY - content.height, width: width, height: notch.height + content.height)
        } else {
            frame = CGRect(x: screen.midX - content.width / 2, y: screen.maxY - menuBar - gap - content.height,
                           width: content.width, height: content.height)
        }
        frame.size.width = min(frame.width, screen.width)
        frame.origin.x = min(max(frame.minX, screen.minX), screen.maxX - frame.width)
        return frame
    }

    /// Whether `point` is on the notch, a little under it included (the pointer cannot be seen on the
    /// notch itself, so its lower edge counts).
    public func isOnNotch(_ point: CGPoint, slack: CGFloat = 2) -> Bool {
        guard let notch else { return false }
        return notch.insetBy(dx: 0, dy: -slack).contains(point)
    }
}
