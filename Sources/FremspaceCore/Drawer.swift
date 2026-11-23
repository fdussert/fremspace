import Foundation

/// The display edge a drawer sits on. A left or right drawer is as high as the display and `size`
/// of its width; the top one is as wide as the display and `size` of its height.
public enum DrawerEdge: String, Codable, CaseIterable {
    case left, right, top

    /// "Left", "Right", "Top": the start of a title.
    public var title: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }

    /// The command that opens and closes the drawer of this edge (a shortcut's and a link's name).
    public var toggleCommand: String { "drawer\(title)" }

    /// The command that sends the active window to the drawer of this edge, or takes it out.
    public var sendCommand: String { "drawerSend\(title)" }
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
    /// How far the zone comes over the display: a fraction of its visible width, or of its
    /// visible height for the top drawer.
    public var size: Double
    public var layout: DrawerLayout
    /// The top drawer only: each of its windows keeps the height it has (the one its app gives it
    /// for what it shows, or the one the owner dragged it to) instead of the drawer's. Fremspace
    /// then sets where the window is and how wide, never how high.
    public var fitsContent: Bool

    public init(edge: DrawerEdge, size: Double, layout: DrawerLayout, fitsContent: Bool = false) {
        self.edge = edge
        self.size = size
        self.layout = layout
        self.fitsContent = fitsContent
    }

    /// Whether the windows of this drawer keep their own height.
    public var keepsWindowHeights: Bool { edge == .top && fitsContent }

    private enum CodingKeys: String, CodingKey {
        case edge, size, layout, fitsContent
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        edge = try c.decode(DrawerEdge.self, forKey: .edge)
        size = try c.decode(Double.self, forKey: .size)
        layout = try c.decode(DrawerLayout.self, forKey: .layout)
        fitsContent = try c.decodeIfPresent(Bool.self, forKey: .fitsContent) ?? false
    }

    /// Written only when it is on, so other files do not change.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(edge, forKey: .edge)
        try c.encode(size, forKey: .size)
        try c.encode(layout, forKey: .layout)
        if fitsContent { try c.encode(fitsContent, forKey: .fitsContent) }
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
