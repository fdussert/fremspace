import Foundation

/// A ready-made way to cut a desktop into slots: the shapes only, the owner chooses the apps.
public struct LayoutPreset: Equatable, Identifiable {
    public let id: String
    public let name: String
    /// What the picture cannot say at its size: "3 slots, 2/3 and two halves".
    public let detail: String
    /// The slots, in reading order (rows from the top, each from the left).
    public let rects: [UnitRect]
}

private let third = 1.0 / 3
/// Two fractions written differently (1/3 + 1/3 and 2/3) are the same place.
private let tolerance = 1e-9

/// The layouts Fremspace comes with. Every cut is on a fraction the editor's dividers stop at, so
/// that a layout made from one is edited like any other.
public let layoutPresets: [LayoutPreset] = [
    LayoutPreset(id: "sideBySide", name: "Side by side", detail: "2 slots, half and half", rects: [
        UnitRect(x: 0, y: 0, w: 0.5, h: 1), UnitRect(x: 0.5, y: 0, w: 0.5, h: 1),
    ]),
    LayoutPreset(id: "topAndBottom", name: "Top and bottom", detail: "2 slots, for a tall display", rects: [
        UnitRect(x: 0, y: 0, w: 1, h: 0.5), UnitRect(x: 0, y: 0.5, w: 1, h: 0.5),
    ]),
    LayoutPreset(id: "mainAndSide", name: "Main and side", detail: "2 slots, 2/3 and 1/3", rects: [
        UnitRect(x: 0, y: 0, w: 2 * third, h: 1), UnitRect(x: 2 * third, y: 0, w: third, h: 1),
    ]),
    LayoutPreset(id: "thirds", name: "Thirds", detail: "3 slots, equal columns", rects: [
        UnitRect(x: 0, y: 0, w: third, h: 1), UnitRect(x: third, y: 0, w: third, h: 1),
        UnitRect(x: 2 * third, y: 0, w: third, h: 1),
    ]),
    LayoutPreset(id: "mainAndTwo", name: "Main and two", detail: "3 slots, 2/3 and two halves", rects: [
        UnitRect(x: 0, y: 0, w: 2 * third, h: 1), UnitRect(x: 2 * third, y: 0, w: third, h: 0.5),
        UnitRect(x: 2 * third, y: 0.5, w: third, h: 0.5),
    ]),
    LayoutPreset(id: "centerStage", name: "Center stage", detail: "3 slots, 1/4, 1/2, 1/4", rects: [
        UnitRect(x: 0, y: 0, w: 0.25, h: 1), UnitRect(x: 0.25, y: 0, w: 0.5, h: 1),
        UnitRect(x: 0.75, y: 0, w: 0.25, h: 1),
    ]),
    LayoutPreset(id: "fourCorners", name: "Four corners", detail: "4 slots, two by two", rects: [
        UnitRect(x: 0, y: 0, w: 0.5, h: 0.5), UnitRect(x: 0.5, y: 0, w: 0.5, h: 0.5),
        UnitRect(x: 0, y: 0.5, w: 0.5, h: 0.5), UnitRect(x: 0.5, y: 0.5, w: 0.5, h: 0.5),
    ]),
    LayoutPreset(id: "mainAndShelf", name: "Main and shelf", detail: "4 slots, three small ones under", rects: [
        UnitRect(x: 0, y: 0, w: 1, h: 0.75), UnitRect(x: 0, y: 0.75, w: third, h: 0.25),
        UnitRect(x: third, y: 0.75, w: third, h: 0.25), UnitRect(x: 2 * third, y: 0.75, w: third, h: 0.25),
    ]),
]

/// Largest first; of two as large, the one read first (higher, then further left). The order in
/// which shapes are handed to the apps of a desktop, so the same input always gives the same desk.
private func bySize(_ a: UnitRect, _ b: UnitRect) -> Bool {
    let areaA = a.w * a.h, areaB = b.w * b.h
    if abs(areaA - areaB) > tolerance { return areaA > areaB }
    if abs(a.y - b.y) > tolerance { return a.y < b.y }
    return a.x < b.x
}

private func inReadingOrder(_ a: UnitRect, _ b: UnitRect) -> Bool {
    if abs(a.y - b.y) > tolerance { return a.y < b.y }
    return a.x < b.x
}

/// The slot that has the most room: where a layout's Focus goes when it is asked for.
public func largestSlot(_ layout: Layout) -> String? {
    layout.slots.sorted { bySize($0.rect, $1.rect) }.first?.id
}

/// A desktop cut again, and what the cut did to the slots it had.
public struct Reshaped: Equatable {
    public var desktop: SpaceSpec
    /// The slots that are new, without an app yet.
    public var added: [String] = []
    /// The slots that are gone (the desktop had more than the shapes), and the slot their apps
    /// went to, stacked: nothing the owner had placed is dropped.
    public var merged: [String] = []
    public var mergedInto: String?
}

/// `desktop` with its slots in the given shapes. The slots it had keep their name, their apps and
/// their options, the one with the most room taking the largest shape and so on down; shapes left
/// over become empty slots, slots left over stack their apps in the smallest shape. A free desktop
/// gets empty slots. `focusOnLargest` gives the desktop's Focus to the slot of the largest shape;
/// without it a Focus stays with its slot when that slot is still there.
public func reshaped(_ desktop: SpaceSpec, to shapes: [UnitRect], focusOnLargest: Bool) -> Reshaped {
    var result = Reshaped(desktop: desktop)
    guard !shapes.isEmpty else { return result }
    let old = (desktop.layout?.slots ?? []).sorted { bySize($0.rect, $1.rect) }
    let ordered = shapes.sorted(by: bySize)
    var taken = Set(old.map(\.id))
    var slots: [Slot] = []
    for (position, rect) in ordered.enumerated() {
        if position < old.count {
            var slot = old[position]
            slot.rect = rect
            slots.append(slot)
        } else {
            var number = slots.count + 1
            while taken.contains("slot\(number)") { number += 1 }
            let id = "slot\(number)"
            taken.insert(id)
            slots.append(Slot(id: id, rect: rect, rule: Rule(bundleID: "")))
            result.added.append(id)
        }
    }
    if old.count > ordered.count, let last = slots.indices.last {
        for extra in old[ordered.count...] {
            result.merged.append(extra.id)
            for rule in extra.rules where !rule.bundleID.isEmpty && !slots[last].rules.contains(rule) {
                slots[last].rules.append(rule)
            }
        }
        // An empty slot that takes apps is no longer empty.
        if slots[last].rules.count > 1 { slots[last].rules.removeAll { $0.bundleID.isEmpty } }
        result.mergedInto = slots[last].id
    }
    let largest = slots.first?.id
    result.desktop.layout = Layout(slots: slots.sorted { inReadingOrder($0.rect, $1.rect) })
    if focusOnLargest {
        result.desktop.focusSlot = largest
    } else if let focus = desktop.focusSlot, !slots.contains(where: { $0.id == focus }) {
        result.desktop.focusSlot = nil
    }
    return result
}

/// How a layout made on one display sits on another, as far as their shapes tell.
public enum DisplayShapeFit: Equatable {
    case fits
    /// Made for a display taller than wide, shown on one wider than tall: its rows come out flat.
    case madeForTall
    /// The other way round: its columns come out narrow.
    case madeForWide
}

/// `madeFor` and `here` are widths over heights; nil when the file does not say (an older one).
public func shapeFit(madeFor: Double?, here: Double) -> DisplayShapeFit {
    guard let madeFor, madeFor > 0, here > 0 else { return .fits }
    if madeFor < 1, here >= 1 { return .madeForTall }
    if madeFor >= 1, here < 1 { return .madeForWide }
    return .fits
}
