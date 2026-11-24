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
    /// Since when secure keyboard input has been on without a break (see `hyperBlock`).
    private var secureSince: Date?
    /// What holds secure keyboard input and blocks the key, once it has for a while.
    private(set) var blockedBy: String?
    /// Called when the key becomes blocked (with what holds the keys) and when it is free again (nil).
    var onBlock: (_ holder: String?) -> Void = { _ in }
    /// Looks every second that the filter is still there and whether secure keyboard input is on,
    /// while Hyper is on (see `verify`).
    private var watch: Timer?
    private static let watchEvery: TimeInterval = 1
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
        watchFilter(on)
        return true
    }

    // MARK: - Without the filter: while secure keyboard input is on

    // Secure keyboard input hides key presses from the filter, not from hot keys: those are
    // matched by the window server itself (owner, 2026-11-24: with the lock screen holding
    // secure input, Caps Lock + T did nothing and Control-Option-Command-T opened the drawer).
    // So while it is on, Caps Lock (F18) is a hot key of its own; while it is held, the keys of
    // Fremspace's own commands are hot keys too, with no modifier, and are let go the moment it
    // is released. Fremspace's commands then work as ever. What is lost until secure input ends
    // is Caps Lock + key for the shortcuts of other apps: no key press can be changed on its way.

    private static let signature: OSType = 0x4652_4D48 // "FRMH"
    private static let leaderID: UInt32 = 1
    private var chordHandler: EventHandlerRef?
    private var leader: EventHotKeyRef?
    private var chords: [EventHotKeyRef] = []
    private var chordActions: [UInt32: () -> Void] = [:]
    private var chordWatch: Timer?
    /// The keyboard said F18 was down at least once while the chords were up: its "up" can then
    /// be believed, as a second way of noticing the release.
    private var keyboardSawLeader = false
    private var chordsSince = Date.distantPast
    /// The longest the command keys stay taken if no release of Caps Lock is ever seen: they are
    /// plain letters, and nobody could type them meanwhile.
    private static let chordsAtMost: TimeInterval = 8

    private func installChordHandler() {
        guard chordHandler == nil else { return }
        var specs = [EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
                     EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == HyperKey.signature else { return OSStatus(eventNotHandledErr) }
            let hyper = Unmanaged<HyperKey>.fromOpaque(userData).takeUnretainedValue()
            let pressed = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            if id.id == HyperKey.leaderID {
                if pressed { hyper.leaderDown() } else { hyper.leaderUp() }
            } else if pressed {
                hyper.chordActions[id.id]?()
            }
            return noErr
        }, specs.count, &specs, Unmanaged.passUnretained(self).toOpaque(), &chordHandler)
    }

    /// Caps Lock as a hot key of its own, for as long as secure keyboard input is on.
    private func setLeader(_ on: Bool) {
        if on, leader == nil {
            installChordHandler()
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(UInt32(Self.f18), 0, EventHotKeyID(signature: Self.signature, id: Self.leaderID),
                                             GetApplicationEventTarget(), 0, &ref)
            leader = status == noErr ? ref : nil
            Log.app.notice("hyper key: secure keyboard input is on; Caps Lock goes through a hot key meanwhile (\(status == noErr ? "registered" : "refused: \(status)", privacy: .public))")
        } else if !on, let leader {
            UnregisterEventHotKey(leader)
            self.leader = nil
            leaderUp()
        }
    }

    private func leaderDown() {
        guard chords.isEmpty, !commandsSuspended else { return }
        held = true
        chordsSince = Date()
        keyboardSawLeader = false
        var next: UInt32 = 100
        for code in 0..<UInt32(128) where code != UInt32(Self.f18) {
            for shift in [false, true] {
                guard let action = command(code, shift) else { continue }
                var ref: EventHotKeyRef?
                let status = RegisterEventHotKey(code, shift ? UInt32(shiftKey) : 0, EventHotKeyID(signature: Self.signature, id: next),
                                                 GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref {
                    chords.append(ref)
                    chordActions[next] = action
                }
                next += 1
            }
        }
        if traces < 12 {
            traces += 1
            Log.app.notice("hyper key: Caps Lock down, as a hot key; \(self.chords.count) command keys taken while it is held")
        }
        // The release comes as an event; missed (it happens to hot keys under load), the plain
        // keys would stay taken: the keyboard's own word, and a deadline, end it too.
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            guard let self else { return }
            let down = CGEventSource.keyState(.hidSystemState, key: Self.f18)
            if down { self.keyboardSawLeader = true }
            if (self.keyboardSawLeader && !down) || Date().timeIntervalSince(self.chordsSince) > Self.chordsAtMost { self.leaderUp() }
        }
        RunLoop.main.add(timer, forMode: .common)
        chordWatch = timer
    }

    private func leaderUp() {
        chordWatch?.invalidate()
        chordWatch = nil
        chords.forEach { UnregisterEventHotKey($0) }
        chords.removeAll()
        chordActions.removeAll()
        held = false
    }

    /// The process that holds secure keyboard input, as the window server records it for the
    /// console session.
    private static func secureInputHolder() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        defer { IOObjectRelease(root) }
        let users = IORegistryEntryCreateCFProperty(root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [[String: Any]]
        return users?.compactMap { ($0["kCGSSessionSecureInputPID"] as? NSNumber)?.int32Value }.first
    }

    /// Secure keyboard input hides every key press from the filter, with nothing told to the app:
    /// the filter is in place and Caps Lock + key does nothing. No app can end it for another;
    /// what can be done is to say so, and what holds it.
    private func checkSecureInput() {
        let secure = IsSecureEventInputEnabled()
        if secure { secureSince = secureSince ?? Date() } else { secureSince = nil }
        setLeader(secure)
        let holder = secure ? Self.secureInputHolder() : nil
        let name = holder.flatMap { NSRunningApplication(processIdentifier: $0) }
        let byLockScreen = holder.map { pid in
            name?.bundleIdentifier == "com.apple.loginwindow" || name == nil && Self.isLoginWindow(pid)
        } ?? false
        let blocked = hyperBlock(secureFor: secureSince.map { Date().timeIntervalSince($0) }, byLockScreen: byLockScreen,
                                 sessionLocked: Engine.sessionIsLocked)
        let by = blocked ? (byLockScreen ? "The lock screen" : name?.localizedName ?? "An app") : nil
        guard by != blockedBy else { return }
        blockedBy = by
        if let by {
            Log.app.notice("hyper key: blocked by secure keyboard input, held by \(by, privacy: .public) for \(Int(Date().timeIntervalSince(self.secureSince ?? Date()))) s")
        } else {
            Log.app.notice("hyper key: secure keyboard input is off again; Caps Lock shortcuts work")
        }
        onBlock(by)
    }

    /// loginwindow is not an app the workspace lists: told by the path of its executable.
    private static func isLoginWindow(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer).hasSuffix("/loginwindow")
    }

    private func watchFilter(_ on: Bool) {
        watch?.invalidate()
        watch = nil
        if !on {
            setLeader(false)
            secureSince = nil
            if blockedBy != nil {
                blockedBy = nil
                onBlock(nil)
            }
        }
        guard on else { return }
        let timer = Timer(timeInterval: Self.watchEvery, repeats: true) { [weak self] _ in self?.verify() }
        timer.tolerance = 0.3
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    /// Whether the window server still has a filter of this process that is switched on.
    private static func filterIsListed() -> Bool {
        var count: UInt32 = 0
        guard CGGetEventTapList(0, nil, &count) == .success, count > 0 else { return false }
        var taps = [CGEventTapInformation](repeating: CGEventTapInformation(), count: Int(count))
        guard CGGetEventTapList(count, &taps, &count) == .success else { return false }
        let own = getpid()
        return taps.prefix(Int(count)).contains { $0.tappingProcess == own && $0.enabled }
    }

    /// While Hyper is on, the filter has to be there: Caps Lock is remapped to a key that only the
    /// filter reads, so without it Caps Lock is dead and every Hyper shortcut with it. macOS took
    /// the filter away once with nothing said to the app (owner, 2026-11-24: after a wake with
    /// other displays, "the drawer no longer works"; the filter had been fine five hours before
    /// and was in the window server's list no more). Switched off, it is switched on again;
    /// gone, it is installed again.
    func verify() {
        guard isOn else { return }
        checkSecureInput()
        if let tap, CFMachPortIsValid(tap), Self.filterIsListed() { return }
        if let tap, CFMachPortIsValid(tap) {
            CGEvent.tapEnable(tap: tap, enable: true)
            if Self.filterIsListed() {
                Log.app.notice("hyper key: the key filter was switched off; it is on again")
                held = false
                swallowed.removeAll()
                return
            }
        }
        stopTap()
        held = false
        if startTap() {
            Log.app.notice("hyper key: the key filter was gone; it is installed again")
        } else {
            Log.app.error("hyper key: the key filter is gone and could not be installed again; tried again in a moment")
        }
    }

    /// Before Fremspace ends: Caps Lock is itself again.
    func stop() {
        guard isOn else { return }
        watchFilter(false)
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
