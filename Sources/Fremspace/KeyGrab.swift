import AppKit
import Carbon.HIToolbox

/// Takes a few keys away from the app in front while something of Fremspace's that never has the
/// keyboard is shown (the map under the notch). Every other key goes on to the app: only the keys
/// the handler answers for are kept. A filter on key presses, there only between `start` and `stop`:
/// like the Hyper key's it sees every key press while it is installed, so it keeps no key, logs no
/// key, and `SECURITY.md` says when it is there.
final class KeyGrab {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    /// Keys whose press was kept: their release goes no further either.
    private var swallowed: Set<Int64> = []
    private var handler: (Int) -> Bool = { _ in false }

    var isOn: Bool { tap != nil }

    /// `handler` gets the key code of a key pressed without ⌘, ⌃ or ⌥ and says whether it kept it.
    /// Main thread. False when the filter could not be installed (no Accessibility).
    @discardableResult
    func start(_ handler: @escaping (_ keyCode: Int) -> Bool) -> Bool {
        self.handler = handler
        if tap != nil { return true }
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let grab = Unmanaged<KeyGrab>.fromOpaque(userInfo).takeUnretainedValue()
            return grab.handle(type, event) ? nil : Unmanaged.passUnretained(event)
        }
        guard let tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                          eventsOfInterest: mask, callback: callback,
                                          userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            Log.app.notice("keys: the key filter could not be installed; the map keeps to the pointer")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(nil, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        swallowed.removeAll()
        handler = { _ in false }
    }

    /// True when the event goes no further.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Bool {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            swallowed.removeAll()
            return false
        }
        guard type == .keyDown || type == .keyUp else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        if type == .keyUp { return swallowed.remove(keyCode) != nil }
        // A shortcut is the app's or Fremspace's own: with a modifier, or with the Hyper key held
        // (this filter sees the key before the Hyper key's adds ⌃⌥⌘ to it).
        guard event.flags.intersection([.maskCommand, .maskControl, .maskAlternate]).isEmpty,
              !CGEventSource.keyState(.hidSystemState, key: HyperKey.f18) else { return false }
        guard handler(Int(keyCode)) else { return false }
        swallowed.insert(keyCode)
        return true
    }
}
