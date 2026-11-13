import CoreGraphics
import Foundation

/// Which half of its slot a window takes while it shares the slot side by side with another.
public enum SplitHalf: String, Equatable {
    case left, right
}

/// A window that shares its slot side by side with `partner`, for as long as both are in `slotID`.
public struct SplitSide: Equatable {
    public var half: SplitHalf
    public var slotID: String
    public var partner: UInt32

    public init(half: SplitHalf, slotID: String, partner: UInt32) {
        self.half = half
        self.slotID = slotID
        self.partner = partner
    }
}

/// One half of a frame, the gap between the two halves.
public func halfFrame(_ frame: CGRect, _ half: SplitHalf, gap: CGFloat) -> CGRect {
    let width = ((frame.width - gap) / 2).rounded(.down)
    switch half {
    case .left: return CGRect(x: frame.minX, y: frame.minY, width: width, height: frame.height)
    case .right: return CGRect(x: frame.minX + width + gap, y: frame.minY, width: frame.maxX - frame.minX - width - gap, height: frame.height)
    }
}

/// One item of an app's menus, as far as finding its "New Window" goes.
public struct MenuShortcut: Equatable {
    public var title: String
    /// The key of its shortcut ("N"), empty when it has none.
    public var key: String
    /// Only ⌘ with the key: no ⇧, ⌥ or ⌃.
    public var commandOnly: Bool

    public init(title: String, key: String, commandOnly: Bool) {
        self.title = title
        self.key = key
        self.commandOnly = commandOnly
    }
}

/// The menu item that opens a new window of the app, among its items in menu order: the first
/// whose shortcut is on N and whose title speaks of a window and not of a private one (an editor
/// has "New File" on ⌘N and "New Window" on ⇧⌘N); else the one on ⌘N alone. Nil when there is none.
public func newWindowItem(_ items: [MenuShortcut]) -> Int? {
    let onN = items.indices.filter { items[$0].key.uppercased() == "N" }
    let windowWords = ["window", "fenêtre", "fenetre", "fenster", "ventana", "finestra", "janela", "venster"]
    let privateWords = ["private", "privé", "prive", "incognito", "inkognito", "privat", "tor"]
    func words(_ title: String) -> [String] {
        title.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
    }
    if let named = onN.first(where: { index in
        let title = words(items[index].title)
        return title.contains(where: { word in windowWords.contains(word) })
            && !title.contains(where: { word in privateWords.contains(where: { word.hasPrefix($0) }) })
    }) {
        return named
    }
    return onN.first { items[$0].commandOnly }
}
