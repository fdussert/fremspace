import AppKit
import Carbon.HIToolbox
import FremspaceCore
import IOKit
import IOKit.hidsystem

/// The Hyper key: Caps Lock held stands for ⌃⌥⌘, so ⌃⌥⌘Space is Caps Lock + Space, with no other
/// tool. Two parts: the keyboard is told that Caps Lock sends F18 (a key no keyboard has), and a
/// filter on key presses reads F18 as "Hyper is held". While it is, a key that is one of Fremspace's
/// shortcuts runs its command; any other key goes on with ⌃⌥⌘ added, for the shortcuts of other
/// apps. Caps Lock no longer locks capitals while this is on.
///
/// What can go wrong, and what is done about it:
/// - Fremspace quits or is killed: the mapping is removed first (`stop`), Caps Lock is itself again
///   (or what the owner had mapped it to before).
/// - The setting is off: a Caps Lock → F18 that Fremspace did not set is somebody else's (the
///   `hidutil` recipe for a Hyper key with another tool) and is left alone.
/// - Fremspace crashes: Caps Lock keeps sending F18, which does nothing, until Fremspace starts
///   again (it sets or removes the mapping at every start) or the session ends.
/// - A key release is missed (the filter was off for a moment, a password field had the keys):
///   "held" comes from the presses and releases of F18 the filter sees, and is dropped when the
///   keyboard says F18 is up and no press of it was seen for a while. Pressing Caps Lock once
///   more also clears it.
final class HyperKey {
    static let f18 = CGKeyCode(kVK_F18)
    private static let property = "UserKeyMapping" as CFString
    private static let sourceKey = "HIDKeyboardModifierMappingSrc"
    private static let destinationKey = "HIDKeyboardModifierMappingDst"

    /// The calls `hidutil property --set` makes (`PrivateCalls`): the mapping lives in the HID
    /// system, not in a file, and holds until it is removed or the session ends. Nil when this
    /// macOS no longer has one of them.
    private static let keyboard: (client: PrivateCalls.KeyboardClient, copy: PrivateCalls.KeyboardCopyProperty,
                                  set: PrivateCalls.KeyboardSetProperty)? = {
        guard let client = PrivateCalls.keyboardClient, let copy = PrivateCalls.keyboardCopyProperty,
              let set = PrivateCalls.keyboardSetProperty else { return nil }
        return (client, copy, set)
    }()
    /// Caps Lock can be remapped on this macOS.
    static var isPossible: Bool { keyboard != nil }

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private(set) var isOn = false
    /// Keys whose press ran a command: their release goes no further either.
    private var swallowed: Set<Int64> = []
    /// F18 is down, as the filter saw it (a held key repeats its press).
    private var held = false
    private var lastPress = Date.distantPast
    /// How long "held" stands without a press of F18 once the keyboard says it is up.
    private static let heldFor: TimeInterval = 10
    /// The first uses are logged (never which key), to tell a filter that sees nothing from one
    /// that sees Caps Lock and not that it is held.
    private var traces = 0
    /// The command for Hyper + key, if it is one of Fremspace's (see `hyperOutcome`).
    var command: (_ keyCode: UInt32, _ shift: Bool) -> (() -> Void)? = { _, _ in nil }
    /// While a shortcut is being typed in Settings, Hyper + key is typed as ⌃⌥⌘ + key.
    var commandsSuspended = false
    /// What Fremspace did to the mapping of Caps Lock, read from and written to `state.json`: a
    /// mapping is removed only when Fremspace set it, also after a crash or a restart.
    var record: () -> HyperMapping? = { nil }
    var remember: (HyperMapping?) -> Void = { _ in }

    /// Turns Hyper on or off. Returns false when it could not be turned on (no Accessibility yet).
    @discardableResult
    func set(_ on: Bool) -> Bool {
        if on {
            guard Self.isPossible else {
                // The filter without the mapping would be Hyper of nothing.
                Log.app.error("hyper key: this macOS no longer has the calls that remap Caps Lock")
                stopTap()
                isOn = false
                return false
            }
            guard startTap() else {
                // Without the filter, a remapped Caps Lock would be a dead key.
                setMapping(false)
                isOn = false
                return false
            }
            setMapping(true)
            Self.turnCapsLockOff()
        } else {
            stopTap()
            setMapping(false)
        }
        if isOn != on { Log.app.info("hyper key \(on ? "on" : "off", privacy: .public)") }
        isOn = on
        return true
    }

    /// Before Fremspace ends: Caps Lock is itself again.
    func stop() {
        guard isOn else { return }
        stopTap()
        setMapping(false)
        isOn = false
    }

    // MARK: - The keyboard mapping

    private static func mappings(_ client: AnyObject, _ copy: PrivateCalls.KeyboardCopyProperty) -> [KeyMapping] {
        let raw = copy(client, property)?.takeRetainedValue() as? [[String: Any]] ?? []
        return raw.compactMap { entry in
            guard let source = (entry[sourceKey] as? NSNumber)?.uint64Value,
                  let destination = (entry[destinationKey] as? NSNumber)?.uint64Value else { return nil }
            return KeyMapping(source: source, destination: destination)
        }
    }

    private func setMapping(_ on: Bool) {
        guard let keyboard = Self.keyboard, let client = keyboard.client(kCFAllocatorDefault)?.takeRetainedValue() else {
            Log.app.error("hyper key: the keyboard settings could not be reached")
            return
        }
        let before = record()
        let change = hyperMappingChange(Self.mappings(client, keyboard.copy), hyper: on, record: before)
        // Remembered before the mapping goes in and forgotten after it went out: a crash in
        // between leaves a record without its mapping, which undoes nothing.
        if on, change.record != before { remember(change.record) }
        if let wanted = change.mappings {
            let raw = wanted.map { [Self.sourceKey: NSNumber(value: $0.source), Self.destinationKey: NSNumber(value: $0.destination)] }
            if !keyboard.set(client, Self.property, raw as NSArray).boolValue {
                Log.app.error("hyper key: the Caps Lock mapping could not be \(on ? "set" : "removed", privacy: .public)")
            } else if !on, before?.replaced.isEmpty == false {
                Log.app.notice("hyper key: the mapping of Caps Lock it had replaced is back")
            }
        }
        if !on, change.record != before { remember(change.record) }
    }

    /// Capitals locked when Hyper comes on would stay locked, with no key left to unlock them.
    private static func turnCapsLockOff() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else { return }
        defer { IOServiceClose(connect) }
        var locked = false
        if IOHIDGetModifierLockState(connect, Int32(kIOHIDCapsLockState), &locked) == KERN_SUCCESS, locked {
            IOHIDSetModifierLockState(connect, Int32(kIOHIDCapsLockState), false)
        }
    }

    // MARK: - The filter on key presses

    private func startTap() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let hyper = Unmanaged<HyperKey>.fromOpaque(userInfo).takeUnretainedValue()
            return hyper.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.app.error("hyper key: the key filter could not be installed (Accessibility not granted?)")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    private func stopTap() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        swallowed.removeAll()
        held = false
    }

    /// True when the event goes no further. Runs on the main thread, for every key press: it only
    /// reads a key state and a table.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // macOS turns a filter off when it was slow once: back on, or Caps Lock would be dead.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            swallowed.removeAll()
            // Its release may have been missed meanwhile.
            held = false
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        // F18 itself is nobody's key.
        if keyCode == Int64(Self.f18) {
            let down = type == .keyDown
            if down != held, traces < 6 {
                traces += 1
                Log.app.notice("hyper key: Caps Lock \(down ? "down" : "up", privacy: .public)")
            }
            held = down
            if down { lastPress = Date() }
            return true
        }
        if type == .keyUp, swallowed.remove(keyCode) != nil { return true }
        let keyboardSaysDown = CGEventSource.keyState(.hidSystemState, key: Self.f18)
        if held, !keyboardSaysDown, Date().timeIntervalSince(lastPress) > Self.heldFor { held = false }
        guard held || keyboardSaysDown else { return false }
        if type == .keyDown, traces < 12 {
            traces += 1
            Log.app.notice("hyper key: a key with Caps Lock held (seen down: \(self.held, privacy: .public), keyboard says down: \(keyboardSaysDown, privacy: .public))")
        }
        let shift = event.flags.contains(.maskShift)
        if type == .keyDown, !commandsSuspended, let action = command(UInt32(keyCode), shift) {
            swallowed.insert(keyCode)
            // A key held down repeats: the command runs once.
            if event.getIntegerValueField(.keyboardEventAutorepeat) == 0 { DispatchQueue.main.async(execute: action) }
            return true
        }
        event.flags.insert([.maskControl, .maskAlternate, .maskCommand])
        return false
    }
}
