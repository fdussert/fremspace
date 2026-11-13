import CoreGraphics
import Foundation

/// A tab being dragged along a row of tabs: where it would land, and how the row looks meanwhile.
public struct ReorderPreview: Equatable {
    /// The position the dragged tab takes if dropped now.
    public var target: Int
    /// How far the dragged tab is drawn from its place: the pointer's travel, kept inside the row.
    public var offset: CGFloat
    /// How far each tab moves aside to make room (0 for the dragged tab and for those not concerned).
    public var shifts: [CGFloat]
    /// The offset that puts the dragged tab exactly in its new place, for the drop.
    public var snap: CGFloat

    public init(target: Int, offset: CGFloat, shifts: [CGFloat], snap: CGFloat) {
        self.target = target
        self.offset = offset
        self.shifts = shifts
        self.snap = snap
    }
}

/// The row while tab `dragged` is `translation` away from its place. A tab gives way when the
/// edge of the dragged tab that leads the move passes its middle: with the middle of the dragged
/// tab instead, a wide tab kept inside the row could never go past a narrow one at the end. Nil
/// when `dragged` is not a tab of the row.
public func reorderPreview(widths: [CGFloat], spacing: CGFloat, dragged: Int, translation: CGFloat) -> ReorderPreview? {
    guard widths.indices.contains(dragged) else { return nil }
    var starts: [CGFloat] = []
    var x: CGFloat = 0
    for width in widths {
        starts.append(x)
        x += width + spacing
    }
    let total = max(0, x - spacing)
    let own = widths[dragged]
    let offset = min(max(translation, -starts[dragged]), total - starts[dragged] - own)
    let leading = starts[dragged] + offset
    let trailing = leading + own
    func middle(_ i: Int) -> CGFloat { starts[i] + widths[i] / 2 }
    var target = dragged
    if offset > 0 {
        target += widths.indices.filter { $0 > dragged && middle($0) < trailing }.count
    } else if offset < 0 {
        target -= widths.indices.filter { $0 < dragged && middle($0) > leading }.count
    }
    var shifts = [CGFloat](repeating: 0, count: widths.count)
    var snap: CGFloat = 0
    if target > dragged {
        for i in (dragged + 1)...target {
            shifts[i] = -(own + spacing)
            snap += widths[i] + spacing
        }
    } else if target < dragged {
        for i in target..<dragged {
            shifts[i] = own + spacing
            snap -= widths[i] + spacing
        }
    }
    return ReorderPreview(target: target, offset: offset, shifts: shifts, snap: snap)
}
