import Foundation

/// A keyboard shortcut the owner chose for a command, instead of its default. `keyCode` is a
/// position on the keyboard (nil: the command has no shortcut); `modifiers` are among "control",
/// "option", "shift" and "command". A name that is none of these (a file edited by hand: "cmd")
/// is kept as it was written, after the others, and makes the shortcut unusable: dropped, it
/// left the command on fewer modifiers than the owner meant, or on the bare key.
public struct Shortcut: Codable, Equatable {
    public var keyCode: UInt32?
    public var modifiers: [String]

    public static let modifierNames = ["control", "option", "shift", "command"]

    public init(keyCode: UInt32?, modifiers: [String] = []) {
        self.keyCode = keyCode
        // One order, so that two shortcuts typed differently compare equal.
        self.modifiers = Shortcut.modifierNames.filter(modifiers.contains)
            + modifiers.filter { !Shortcut.modifierNames.contains($0) }
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(keyCode: try c.decodeIfPresent(UInt32.self, forKey: .keyCode),
                  modifiers: try c.decodeIfPresent([String].self, forKey: .modifiers) ?? [])
    }

    /// A shortcut that would fire while typing is refused: it needs Control, Option or Command
    /// (Shift alone types a capital), and no modifier that is not one.
    public var isUsable: Bool {
        guard keyCode != nil else { return true }
        return modifiers.allSatisfy(Shortcut.modifierNames.contains) && modifiers.contains { $0 != "shift" }
    }
}

/// The command already using `shortcut` among `effective` (command id → its shortcut), other than
/// `command` itself. A command without shortcut never conflicts.
public func shortcutConflict(_ shortcut: Shortcut, for command: String, effective: [String: Shortcut]) -> String? {
    guard shortcut.keyCode != nil else { return nil }
    return effective.first { $0.key != command && $0.value == shortcut }?.key
}
