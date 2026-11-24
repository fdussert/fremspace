import Foundation

/// What Fremspace does with a key pressed while the Hyper key (Caps Lock) is held.
public enum HyperOutcome: Equatable {
    /// The key is one of Fremspace's own shortcuts: the command runs and the key goes no further.
    case run(String)
    /// The key goes on as ⌃⌥⌘ + key, for the shortcuts of other apps.
    case addModifiers
}

/// Hyper stands for ⌃⌥⌘: Hyper + key runs the command whose shortcut is ⌃⌥⌘ + key (with ⇧ when
/// Shift is held too). `effective`: command id → its shortcut.
public func hyperOutcome(keyCode: UInt32, shift: Bool, effective: [String: Shortcut]) -> HyperOutcome {
    let wanted = Shortcut(keyCode: keyCode, modifiers: ["control", "option", "command"] + (shift ? ["shift"] : []))
    // Sorted, so that two commands on one shortcut (a file edited by hand) always give the same one.
    if let command = effective.filter({ $0.value == wanted }).keys.sorted().first { return .run(command) }
    return .addModifiers
}

/// One entry of the keyboard's `UserKeyMapping` (what `hidutil` sets): the key `source` sends
/// `destination`. HID usages, with the keyboard page in front (0x7_0000_0000).
public struct KeyMapping: Codable, Equatable {
    public var source: UInt64
    public var destination: UInt64

    public static let capsLock: UInt64 = 0x7_0000_0039
    public static let f18: UInt64 = 0x7_0000_006D
    /// Caps Lock sends F18, a key no keyboard has: Fremspace reads it as Hyper.
    public static let hyper = KeyMapping(source: capsLock, destination: f18)

    public init(source: UInt64, destination: UInt64) {
        self.source = source
        self.destination = destination
    }
}

/// What Fremspace did to the keyboard so that Caps Lock is Hyper, kept in `state.json`: it removes
/// only a mapping it set itself, and puts back what that mapping replaced.
public struct HyperMapping: Codable, Equatable {
    /// The mappings of Caps Lock that gave way (the owner's Caps Lock → Escape).
    public var replaced: [KeyMapping]

    public init(replaced: [KeyMapping] = []) {
        self.replaced = replaced
    }
}

/// The mappings to set so that Hyper is on or off (nil when nothing has to change), and what to
/// remember of it. Every mapping of another key is kept as it is.
///
/// On: a Caps Lock → F18 that is already there stays, and stays whose it was (Fremspace's own
/// from before a restart when `record` says so, else another tool's: the usual `hidutil` recipe
/// for a Hyper key). Otherwise it is added in place of any other mapping of Caps Lock, which is
/// remembered.
/// Off: only a mapping Fremspace set is removed, and what it replaced comes back. Without a
/// record nothing is touched: the setting is off by default, and Fremspace then has no business
/// with somebody else's Caps Lock. A record without the mapping is from a session that ended,
/// taking the mapping with it: it is forgotten and nothing is put back.
public func hyperMappingChange(_ current: [KeyMapping], hyper on: Bool,
                               record: HyperMapping?) -> (mappings: [KeyMapping]?, record: HyperMapping?) {
    if on {
        if current.contains(.hyper) { return (nil, record) }
        let replaced = current.filter { $0.source == KeyMapping.capsLock }
        return (current.filter { $0.source != KeyMapping.capsLock } + [.hyper], HyperMapping(replaced: replaced))
    }
    guard let record, current.contains(.hyper) else { return (nil, nil) }
    var wanted = current.filter { $0 != .hyper }
    for mapping in record.replaced where !wanted.contains(where: { $0.source == mapping.source }) {
        wanted.append(mapping)
    }
    return (wanted, nil)
}

/// What secure keyboard input does to the Hyper key. While an app holds it (a password field has
/// the keys, or the app asked for it), macOS hides key presses from every other app: the filter
/// that reads Caps Lock sees nothing, and Caps Lock + key does nothing. It ends when the field is
/// left. The lock screen sometimes keeps it after an unlock, and then it does not end (owner,
/// 2026-11-24: "the key is gone again", twice in a day, each time after a wake).
///
/// `secureFor`: how long it has been on without a break, nil when it is off. `blocked` is for
/// the Status page; `tell` for a notification, kept for the case nothing on screen explains:
/// the lock screen holding it while the session is unlocked. Behind the lock screen nothing is
/// said: it is doing its job.
public func hyperBlock(secureFor seconds: TimeInterval?, byLockScreen: Bool, sessionLocked: Bool) -> (blocked: Bool, tell: Bool) {
    guard let seconds, !sessionLocked else { return (false, false) }
    if byLockScreen { return (seconds >= 10, seconds >= 10) }
    return (seconds >= 20, false)
}

