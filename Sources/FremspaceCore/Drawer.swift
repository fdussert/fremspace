import Foundation

/// The display edge a drawer sits on.
public enum DrawerEdge: String, Codable {
    case left, right
}

/// A region of the drawer zone, in fractions of the zone. Any window can be sent to it by hand; the
/// windows its rules match go to it by themselves.
public struct DrawerSlot: Codable, Equatable {
    public var id: String
    public var rect: UnitRect
    /// Apps whose windows join this slot on their own; empty for a slot filled by hand only.
    public var rules: [Rule]

    public init(id: String, rect: UnitRect, rules: [Rule] = []) {
        self.id = id
        self.rect = rect
        self.rules = rules
    }

    private enum CodingKeys: String, CodingKey {
        case id, rect, rules
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        rect = try c.decode(UnitRect.self, forKey: .rect)
        rules = try c.decodeIfPresent([Rule].self, forKey: .rules) ?? []
    }

    /// Without rules the slot is written as before.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(rect, forKey: .rect)
        if !rules.isEmpty { try c.encode(rules, forKey: .rules) }
    }
}

public struct DrawerLayout: Codable, Equatable {
    public var slots: [DrawerSlot]

    public init(slots: [DrawerSlot]) {
        self.slots = slots
    }
}

/// A zone along one edge of a display, over the layout of whichever desktop it shows, holding the
/// windows the owner sent there.
public struct DrawerSpec: Codable, Equatable {
    public var edge: DrawerEdge
    /// Width of the zone, as a fraction of the display's visible width.
    public var size: Double
    public var layout: DrawerLayout

    public init(edge: DrawerEdge, size: Double, layout: DrawerLayout) {
        self.edge = edge
        self.size = size
        self.layout = layout
    }
}

/// The drawer slot (`"<edge>.<slot id>"`) whose rules take `window`, if any: the first in the order of
/// the drawers and of their slots. A window that matches a slot of `layout` (the layout of the desktop
/// it is on) belongs to that layout instead.
public func drawerSlotKey(for window: WindowInfo, in drawers: [DrawerSpec], layout: Layout? = nil) -> String? {
    guard window.isManageable else { return nil }
    if let layout, layout.slots.contains(where: { matches($0, window) }) { return nil }
    for drawer in drawers {
        if let slot = drawer.layout.slots.first(where: { slot in slot.rules.contains { matches($0, window) } }) {
            return "\(drawer.edge.rawValue).\(slot.id)"
        }
    }
    return nil
}
