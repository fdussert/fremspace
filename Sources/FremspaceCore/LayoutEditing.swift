import CoreGraphics

/// The orientation of a cut: `.vertical` is a vertical line (left | right), `.horizontal` a
/// horizontal one (top / bottom).
public enum Axis: Equatable {
    case vertical, horizontal
}

private let epsilon = 1e-9
private func same(_ a: Double, _ b: Double) -> Bool { abs(a - b) < epsilon }

/// Cuts slot `id` in two halves; the new slot takes the right (vertical cut) or bottom half.
public func split(_ layout: Layout, slot id: String, along axis: Axis, newID: String, rule: Rule) -> Layout {
    var out = layout
    guard let i = out.slots.firstIndex(where: { $0.id == id }) else { return layout }
    let r = out.slots[i].rect
    let (kept, added): (UnitRect, UnitRect) = axis == .vertical
        ? (UnitRect(x: r.x, y: r.y, w: r.w / 2, h: r.h), UnitRect(x: r.x + r.w / 2, y: r.y, w: r.w / 2, h: r.h))
        : (UnitRect(x: r.x, y: r.y, w: r.w, h: r.h / 2), UnitRect(x: r.x, y: r.y + r.h / 2, w: r.w, h: r.h / 2))
    out.slots[i].rect = kept
    out.slots.insert(Slot(id: newID, rect: added, rule: rule), at: i + 1)
    return out
}

/// Removes slot `id`; a neighbour sharing one of its whole edges grows into the space (left, right,
/// top, then bottom neighbour). Without one, the space stays empty.
public func remove(_ layout: Layout, slot id: String) -> Layout {
    var out = layout
    guard let i = out.slots.firstIndex(where: { $0.id == id }) else { return layout }
    let r = out.slots.remove(at: i).rect
    if let j = out.slots.firstIndex(where: { same($0.rect.y, r.y) && same($0.rect.h, r.h) && same($0.rect.x + $0.rect.w, r.x) }) {
        out.slots[j].rect.w += r.w
    } else if let j = out.slots.firstIndex(where: { same($0.rect.y, r.y) && same($0.rect.h, r.h) && same($0.rect.x, r.x + r.w) }) {
        out.slots[j].rect.x = r.x
        out.slots[j].rect.w += r.w
    } else if let j = out.slots.firstIndex(where: { same($0.rect.x, r.x) && same($0.rect.w, r.w) && same($0.rect.y + $0.rect.h, r.y) }) {
        out.slots[j].rect.h += r.h
    } else if let j = out.slots.firstIndex(where: { same($0.rect.x, r.x) && same($0.rect.w, r.w) && same($0.rect.y, r.y + r.h) }) {
        out.slots[j].rect.y = r.y
        out.slots[j].rect.h += r.h
    }
    return out
}

/// An inner edge shared by slots on both sides; moving it resizes all of them.
public struct Divider: Equatable {
    public var axis: Axis
    public var position: Double
    public var before: [String]
    public var after: [String]

    public init(axis: Axis, position: Double, before: [String], after: [String]) {
        self.axis = axis
        self.position = position
        self.before = before
        self.after = after
    }
}

public func dividers(_ layout: Layout) -> [Divider] {
    var result: [Divider] = []
    for axis in [Axis.vertical, .horizontal] {
        let start: (Slot) -> Double = { axis == .vertical ? $0.rect.x : $0.rect.y }
        let end: (Slot) -> Double = { axis == .vertical ? $0.rect.x + $0.rect.w : $0.rect.y + $0.rect.h }
        var positions: [Double] = []
        for slot in layout.slots where end(slot) < 1 - epsilon && !positions.contains(where: { same($0, end(slot)) }) {
            positions.append(end(slot))
        }
        for p in positions.sorted() {
            let before = layout.slots.filter { same(end($0), p) }.map(\.id)
            let after = layout.slots.filter { same(start($0), p) }.map(\.id)
            if !before.isEmpty && !after.isEmpty { result.append(Divider(axis: axis, position: p, before: before, after: after)) }
        }
    }
    return result
}

/// Moves `divider` towards `position`, snapped to the stops of an axis `length` points long, and
/// clamped so every slot on both sides keeps at least the smallest stop. Unchanged when no stop fits.
public func move(_ layout: Layout, divider: Divider, to position: Double, length: CGFloat) -> Layout {
    let stops = Fractions.stops(forWidth: length)
    guard let smallest = stops.first else { return layout }
    let vertical = divider.axis == .vertical
    let slots = layout.slots
    var lower = slots.filter { divider.before.contains($0.id) }.map { (vertical ? $0.rect.x : $0.rect.y) + smallest }.max() ?? 0
    var upper = slots.filter { divider.after.contains($0.id) }.map { (vertical ? $0.rect.x + $0.rect.w : $0.rect.y + $0.rect.h) - smallest }.min() ?? 1
    // The divider line may cross rows that leave a gap (after Remove or Capture): a slot growing
    // into its row must stop at the next slot of that row.
    func start(_ r: UnitRect) -> Double { vertical ? r.x : r.y }
    func end(_ r: UnitRect) -> Double { vertical ? r.x + r.w : r.y + r.h }
    func sameRow(_ a: UnitRect, _ b: UnitRect) -> Bool {
        vertical ? (a.y < b.y + b.h - epsilon && b.y < a.y + a.h - epsilon) : (a.x < b.x + b.w - epsilon && b.x < a.x + a.w - epsilon)
    }
    let moving = Set(divider.before + divider.after)
    for b in slots where divider.before.contains(b.id) {
        for other in slots where !moving.contains(other.id) && sameRow(b.rect, other.rect) && start(other.rect) >= end(b.rect) - epsilon {
            upper = min(upper, start(other.rect))
        }
    }
    for a in slots where divider.after.contains(a.id) {
        for other in slots where !moving.contains(other.id) && sameRow(a.rect, other.rect) && end(other.rect) <= start(a.rect) + epsilon {
            lower = max(lower, end(other.rect))
        }
    }
    let candidates = stops.filter { $0 >= lower - epsilon && $0 <= upper + epsilon }
    guard let target = candidates.min(by: { abs($0 - position) < abs($1 - position) }) else { return layout }
    var out = layout
    for i in out.slots.indices {
        if divider.before.contains(out.slots[i].id) {
            if vertical { out.slots[i].rect.w = target - out.slots[i].rect.x } else { out.slots[i].rect.h = target - out.slots[i].rect.y }
        } else if divider.after.contains(out.slots[i].id) {
            if vertical {
                out.slots[i].rect.w = out.slots[i].rect.x + out.slots[i].rect.w - target
                out.slots[i].rect.x = target
            } else {
                out.slots[i].rect.h = out.slots[i].rect.y + out.slots[i].rect.h - target
                out.slots[i].rect.y = target
            }
        }
    }
    return out
}

/// The layout after the owner resized the window of slot `id` by hand, from the slot's frame `old`
/// to `new` (AX coordinates, on a display whose visible frame is `visible`): each inner edge that
/// moved takes its divider along, to the nearest clean fraction, so the slots on its other side
/// follow. Nil when nothing changes: the window was moved, not resized; the edge is the screen's;
/// it moved less than `tolerance`; or no clean fraction is nearer than where the divider is.
public func resized(_ layout: Layout, slot id: String, from old: CGRect, to new: CGRect, visible: CGRect,
                    tolerance: CGFloat = 12) -> Layout? {
    guard visible.width > 0, visible.height > 0, layout.slots.contains(where: { $0.id == id }) else { return nil }
    var out = layout
    func drag(_ axis: Axis, after: Bool, to point: CGFloat) {
        guard let divider = dividers(out).first(where: { $0.axis == axis && (after ? $0.after : $0.before).contains(id) }) else { return }
        let position = axis == .vertical ? (point - visible.minX) / visible.width : (point - visible.minY) / visible.height
        out = move(out, divider: divider, to: Double(position), length: visible.width)
    }
    // A move shifts both sides alike; a resize changes the size.
    if abs(new.width - old.width) > tolerance {
        if abs(new.minX - old.minX) > tolerance { drag(.vertical, after: true, to: new.minX) }
        if abs(new.maxX - old.maxX) > tolerance { drag(.vertical, after: false, to: new.maxX) }
    }
    if abs(new.height - old.height) > tolerance {
        if abs(new.minY - old.minY) > tolerance { drag(.horizontal, after: true, to: new.minY) }
        if abs(new.maxY - old.maxY) > tolerance { drag(.horizontal, after: false, to: new.maxY) }
    }
    return out == layout ? nil : out
}

/// The layout with the places of two slots exchanged: each keeps its apps and options and takes the
/// other's rectangle. Unchanged when one of them is not in the layout.
public func swapped(_ layout: Layout, _ a: String, _ b: String) -> Layout {
    guard a != b, let i = layout.slots.firstIndex(where: { $0.id == a }),
          let j = layout.slots.firstIndex(where: { $0.id == b }) else { return layout }
    var out = layout
    out.slots[i].rect = layout.slots[j].rect
    out.slots[j].rect = layout.slots[i].rect
    return out
}

/// Nil when the layout can be saved; else why not.
public func isValid(_ layout: Layout) -> String? {
    var seen: Set<String> = []
    for slot in layout.slots {
        if !seen.insert(slot.id).inserted { return "Two slots are named \"\(slot.id)\"." }
        let r = slot.rect
        if r.x < -epsilon || r.y < -epsilon || r.w <= epsilon || r.h <= epsilon
            || r.x + r.w > 1 + epsilon || r.y + r.h > 1 + epsilon {
            return "Slot \"\(slot.id)\" is outside the display."
        }
    }
    for (i, a) in layout.slots.enumerated() {
        for b in layout.slots[(i + 1)...] where overlaps(a.rect, b.rect) {
            return "Slots \"\(a.id)\" and \"\(b.id)\" overlap."
        }
    }
    return nil
}

/// Whether cutting slot `id` in halves keeps both halves at least the smallest stop of an axis
/// `length` points long (else the new divider could never move).
public func canSplit(_ layout: Layout, slot id: String, along axis: Axis, length: CGFloat) -> Bool {
    guard let slot = layout.slots.first(where: { $0.id == id }), let smallest = Fractions.stops(forWidth: length).first else { return false }
    let half = (axis == .vertical ? slot.rect.w : slot.rect.h) / 2
    return half >= smallest - epsilon
}
