import Carbon.HIToolbox

/// Global hotkeys through Carbon's `RegisterEventHotKey`: no Accessibility or Input Monitoring
/// needed, and the key press is consumed.
final class Hotkeys {
    typealias Combo = (keyCode: UInt32, modifiers: UInt32)

    /// ⌃⌥⌘ plus a key.
    static func hyper(_ keyCode: Int) -> Combo {
        (UInt32(keyCode), UInt32(controlKey | optionKey | cmdKey))
    }

    static let focusToggle = hyper(kVK_Space)
    static let reapply = hyper(kVK_ANSI_R)
    static let pause = hyper(kVK_ANSI_P)
    /// L for the left drawer, D ("droite") for the right one (owner, 2026-11-10).
    static let drawerLeft = hyper(keyCode(for: "l", fallback: kVK_ANSI_L))
    static let drawerRight = hyper(keyCode(for: "d", fallback: kVK_ANSI_D))
    static let openAdmin = hyper(keyCode(for: ",", fallback: kVK_ANSI_Comma))
    static let windowMenu = hyper(keyCode(for: "w", fallback: kVK_ANSI_W))
    /// K for the palette: windows, apps, desktops and commands by name.
    static let palette = hyper(keyCode(for: "k", fallback: kVK_ANSI_K))

    /// The key that types `character` on the current keyboard layout. Key codes name positions on a
    /// US keyboard: on the owner's AZERTY keyboard kVK_ANSI_W is the Z key and kVK_ANSI_M the comma
    /// key (⌃⌥⌘W and ⌃⌥⌘, never fired, 2026-11-09). Keys that sit at the same place on both
    /// (R, P, D, C, E, F, G, T, arrows) did.
    static func keyCode(for character: Character, fallback: Int) -> Int {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return fallback }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        let wanted = String(character).lowercased()
        return data.withUnsafeBytes { raw -> Int in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return fallback }
            for code in 0..<128 {
                var deadKeys: UInt32 = 0
                var length = 0
                var chars = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                if status == noErr, length > 0, String(utf16CodeUnits: chars, count: length).lowercased() == wanted {
                    return code
                }
            }
            return fallback
        }
    }
    static let slotLeft = hyper(kVK_LeftArrow)
    static let slotRight = hyper(kVK_RightArrow)
    static let slotUp = hyper(kVK_UpArrow)
    static let slotDown = hyper(kVK_DownArrow)
    /// The first four scenes of the configuration in use, on the digit keys.
    static let scenes = [hyper(kVK_ANSI_1), hyper(kVK_ANSI_2), hyper(kVK_ANSI_3), hyper(kVK_ANSI_4)]
    /// The slot keys with Shift: the active window's slot trades places with the one on that side.
    static func hyperShift(_ keyCode: Int) -> Combo {
        (UInt32(keyCode), UInt32(controlKey | optionKey | cmdKey | shiftKey))
    }
    static let slotSwapLeft = hyperShift(kVK_LeftArrow)
    static let slotSwapRight = hyperShift(kVK_RightArrow)
    static let slotSwapUp = hyperShift(kVK_UpArrow)
    static let slotSwapDown = hyperShift(kVK_DownArrow)
    /// Through the windows stacked in the active window's slot, and back with Shift.
    static let stackNext = hyper(kVK_Tab)
    static let splitNew = hyper(keyCode(for: "s", fallback: kVK_ANSI_S))
    static let stackPrevious: Combo = (UInt32(kVK_Tab), UInt32(controlKey | optionKey | cmdKey | shiftKey))
    /// The drawer keys with Shift: send the active window to that drawer, or take it out.
    static let drawerSendLeft: Combo = (drawerLeft.0, UInt32(controlKey | optionKey | cmdKey | shiftKey))
    static let drawerSendRight: Combo = (drawerRight.0, UInt32(controlKey | optionKey | cmdKey | shiftKey))

    private static let signature: OSType = 0x4652_454D // "FREM"

    private var actions: [UInt32: () -> Void] = [:]
    fileprivate var labels: [UInt32: String] = [:]
    private var refs: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    private var nextID: UInt32 = 0

    /// Lets go of every hotkey: before registering the owner's new choices, and while a shortcut is
    /// being typed in Settings (else the keys would run the command instead of being recorded).
    func unregisterAll() {
        refs.forEach { UnregisterEventHotKey($0) }
        refs.removeAll()
        actions.removeAll()
        labels.removeAll()
    }

    /// The character the key at `keyCode` types on the current layout, nil when it types none.
    static func character(forKeyCode keyCode: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let property = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(property).takeUnretainedValue() as Data
        return data.withUnsafeBytes { raw -> String? in
            guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var length = 0
            var chars = [UniChar](repeating: 0, count: 4)
            let status = UCKeyTranslate(layout, UInt16(keyCode), UInt16(kUCKeyActionDown), 0, UInt32(LMGetKbdType()),
                                        OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
            guard status == noErr, length > 0 else { return nil }
            let text = String(utf16CodeUnits: chars, count: length).trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text.uppercased()
        }
    }

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr else { return status }
            let hotkeys = Unmanaged<Hotkeys>.fromOpaque(userData).takeUnretainedValue()
            Log.app.info("hotkey \(hotkeys.labels[id.id] ?? "?", privacy: .public) pressed")
            hotkeys.actions[id.id]?()
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    deinit {
        refs.forEach { UnregisterEventHotKey($0) }
        if let handler { RemoveEventHandler(handler) }
    }

    /// Registers `combo`; returns false (and logs) when the system refuses it. Another app holding
    /// the same combo (Rectangle) is usually NOT reported: registration succeeds and that app keeps
    /// receiving the keys (seen on the owner's Mac, 2026-11-09).
    @discardableResult
    func register(_ combo: Combo, label: String = "", _ action: @escaping () -> Void) -> Bool {
        nextID += 1
        let id = nextID
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.modifiers, EventHotKeyID(signature: Self.signature, id: id),
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.app.error("hotkey \(combo.keyCode) could not be registered (\(status))")
            return false
        }
        refs.append(ref)
        actions[id] = action
        labels[id] = label
        return true
    }
}
