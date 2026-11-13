import CoreGraphics
import Foundation

/// When the picture of a window is taken again. A picture is reused while it is fresh, so opening
/// the palette twice in a row does not capture every window twice.
public struct PreviewLedger {
    /// How long a picture stands for its window.
    public var freshFor: TimeInterval
    private var taken: [UInt32: Date] = [:]

    public init(freshFor: TimeInterval = 1.5) {
        self.freshFor = freshFor
    }

    /// The windows of `ids` to capture now, in the order given and each once: those never captured,
    /// and those whose picture is older than `freshFor`.
    public func due(_ ids: [UInt32], now: Date) -> [UInt32] {
        var seen: Set<UInt32> = []
        return ids.filter { id in
            guard seen.insert(id).inserted else { return false }
            guard let date = taken[id] else { return true }
            return now.timeIntervalSince(date) >= freshFor
        }
    }

    public mutating func took(_ id: UInt32, at date: Date) {
        taken[id] = date
    }

    /// Forgets the windows that are gone. Returns them, for their pictures to be dropped.
    @discardableResult
    public mutating func keep(_ alive: Set<UInt32>) -> Set<UInt32> {
        let gone = Set(taken.keys).subtracting(alive)
        for id in gone { taken[id] = nil }
        return gone
    }

    public mutating func forgetAll() {
        taken = [:]
    }
}

/// The size a picture is kept at: the window's proportions, its longest side at most `longest`
/// pixels. A small window is never enlarged.
public func previewSize(of window: CGSize, longest: CGFloat) -> CGSize {
    guard window.width >= 1, window.height >= 1, longest >= 1 else { return .zero }
    let scale = min(1, longest / max(window.width, window.height))
    return CGSize(width: max(1, (window.width * scale).rounded()), height: max(1, (window.height * scale).rounded()))
}

/// The slots of a desktop being edited that are as saved: same place, same apps, on a desktop of
/// the same name. Only those show the picture of the window they hold in the editor, because the
/// picture is what is on screen, not what is being edited.
public func slotsAsSaved(edited: SpaceSpec, saved: SpaceSpec?) -> Set<String> {
    guard let saved, saved.label == edited.label, let was = saved.layout, let now = edited.layout else { return [] }
    let before = Dictionary(was.slots.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    return Set(now.slots.filter { slot in
        guard let old = before[slot.id] else { return false }
        return old.rect == slot.rect && old.rules == slot.rules
    }.map(\.id))
}

/// A window of a slot, as the maps and the editor need it to choose the one they draw.
public struct SlotWindow: Equatable {
    public var id: UInt32
    public var onScreen: Bool
    public var minimized: Bool

    public init(id: UInt32, onScreen: Bool, minimized: Bool) {
        self.id = id
        self.onScreen = onScreen
        self.minimized = minimized
    }
}

/// Of the windows of a slot, given front to back, the one that stands for the slot: the first on
/// screen, else (a desktop that is not shown) the first that is not minimised, else the first.
/// The window list gives a minimised window before the one in front as often as not, and a
/// minimised window has no picture.
public func slotFront(_ windows: [SlotWindow]) -> SlotWindow? {
    windows.first { $0.onScreen && !$0.minimized } ?? windows.first { !$0.minimized } ?? windows.first
}
