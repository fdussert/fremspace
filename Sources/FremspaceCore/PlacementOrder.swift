import CoreGraphics

/// A window Fremspace is about to resize, from its current frame to its slot frame.
public struct Move: Equatable {
    public var id: UInt32
    public var from: CGRect
    public var to: CGRect

    public init(id: UInt32, from: CGRect, to: CGRect) {
        self.id = id
        self.from = from
        self.to = to
    }

    var grows: Bool { to.width * to.height >= from.width * from.height }
}

/// The order to apply `moves` in so that windows stacked in a slot do not flash one after the
/// other: growing windows first, front to back (the front one covers the rest at once), then
/// shrinking windows, back to front (the front one keeps covering until it shrinks last).
/// Windows missing from `frontToBack` go last in their group.
public func placementOrder(_ moves: [Move], frontToBack: [UInt32]) -> [UInt32] {
    let rank = Dictionary(frontToBack.enumerated().map { ($1, $0) }, uniquingKeysWith: { first, _ in first })
    let unknown = Int.max
    let growing = moves.filter(\.grows).sorted { (rank[$0.id] ?? unknown) < (rank[$1.id] ?? unknown) }
    let shrinking = moves.filter { !$0.grows }.sorted { lhs, rhs in
        let l = rank[lhs.id], r = rank[rhs.id]
        switch (l, r) {
        case let (l?, r?): return l > r
        case (_?, nil): return true
        default: return false
        }
    }
    return growing.map(\.id) + shrinking.map(\.id)
}

/// Whether a window kept a frame larger than its slot after placement: its app has a minimum size
/// the slot cannot give. A smaller window (being resized by the user) does not count.
public func refusesSlot(actual: CGRect, slot: CGRect, tolerance: CGFloat) -> Bool {
    actual.width > slot.width + tolerance || actual.height > slot.height + tolerance
}

/// What to do with a window read back a moment after Fremspace set its frame to `slot`.
public enum FitVerdict: Equatable {
    /// It took the slot frame.
    case fits
    /// It kept a larger size: its app's minimum size does not fit the slot. Leave it unlocked.
    case refuses
    /// It is smaller or elsewhere (some apps drop a resize that follows the user's own): set it again.
    case resizeAgain
}

public func fitVerdict(actual: CGRect, slot: CGRect, tolerance: CGFloat) -> FitVerdict {
    if refusesSlot(actual: actual, slot: slot, tolerance: tolerance) { return .refuses }
    let close = abs(actual.minX - slot.minX) <= tolerance && abs(actual.minY - slot.minY) <= tolerance
        && abs(actual.width - slot.width) <= tolerance && abs(actual.height - slot.height) <= tolerance
    return close ? .fits : .resizeAgain
}

/// Whether a window that left its slot frame was moved (same size) rather than resized. Only a move
/// can drop a window into another slot.
public func isMove(actual: CGRect, slot: CGRect, tolerance: CGFloat) -> Bool {
    abs(actual.width - slot.width) <= tolerance && abs(actual.height - slot.height) <= tolerance
}
